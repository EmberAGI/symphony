defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.{AgentRuntime, Config, Linear.Issue, PromptBuilder, Runtime.ProcessOwnership, Tracker, Workspace}

  @type worker_host :: String.t() | nil
  @owned_session_registration_timeout_ms 5_000
  @delegation_turn_option_keys [
    :turn_timeout_ms,
    :start_timeout_ms,
    :heartbeat_interval_ms,
    :status_read_timeout_ms,
    :max_indeterminate_reads,
    :stale_working_ms,
    :max_recovery_attempts,
    :settle_window_ms
  ]

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    opts = Keyword.put_new(opts, :turn_timeout_ms, Config.settings!().codex.turn_timeout_ms)
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        case run_error_action(issue, reason) do
          {:exit, exit_reason} ->
            exit(exit_reason)
        end
    end
  end

  defp run_error_action(issue, reason) do
    if AgentRuntime.provider_auth_failure?(reason) do
      provider_auth_failure = AgentRuntime.provider_auth_failure(reason)

      Logger.error("Agent run blocked by provider authentication for #{issue_context(issue)}: #{AgentRuntime.provider_auth_failure_summary(provider_auth_failure)}")

      {:exit, provider_auth_failure}
    else
      classified_run_error_action(issue, reason)
    end
  end

  defp classified_run_error_action(issue, reason) do
    case AgentRuntime.classify_failure(reason, runner_failure_context(issue)) do
      {:irrecoverable, failure} ->
        Logger.error("Agent run blocked by irrecoverable runtime failure for #{issue_context(issue)}: #{failure.retry_reason}")
        {:exit, {:irrecoverable_runtime_failed, failure}}

      {:retryable, failure} ->
        retry_reason = Map.get(failure, :retry_reason, "retryable_runtime_failure")
        Logger.error("Agent run failed for #{issue_context(issue)}: #{retry_reason}")
        {:exit, {:agent_runtime_failed, reason}}
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        case process_ownership_environment(issue, opts) do
          {:ok, ownership_env} ->
            run_with_workspace_hooks(
              workspace,
              issue,
              codex_update_recipient,
              opts,
              worker_host,
              ownership_env
            )

          result ->
            result
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_with_workspace_hooks(
         workspace,
         issue,
         codex_update_recipient,
         opts,
         worker_host,
         ownership_env
       ) do
    case Workspace.run_before_run_hook(workspace, issue, worker_host, ownership_env) do
      :ok ->
        opts = Keyword.put(opts, :process_ownership_env, ownership_env)
        run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, ownership_env)

      result ->
        finish_with_after_run_hook(
          result,
          workspace,
          issue,
          worker_host,
          ownership_env
        )
    end
  catch
    kind, reason ->
      _ = Workspace.run_after_run_hook(workspace, issue, worker_host, ownership_env)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(
         workspace,
         issue,
         codex_update_recipient,
         opts,
         worker_host,
         ownership_env
       ) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    session_opts =
      [
        issue: issue,
        worker_host: worker_host,
        run_id: Keyword.get(opts, :run_id)
      ]
      |> put_optional(:role, Keyword.get(opts, :role))
      |> put_optional(:execution_generation, Keyword.get(opts, :execution_generation))
      |> put_optional(:runtime_generation, Keyword.get(opts, :runtime_generation))
      |> put_optional(:source_ref, Keyword.get(opts, :source_ref))
      |> put_optional(:tool_config_path, Keyword.get(opts, :tool_config_path))
      |> put_optional(:tool_config_sha256, Keyword.get(opts, :tool_config_sha256))
      |> put_optional(:process_ownership_env, Keyword.get(opts, :process_ownership_env))
      |> put_optional(:delegation_transport, Keyword.get(opts, :delegation_transport))
      |> put_optional(:delegation_transport_context, Keyword.get(opts, :delegation_transport_context))

    case AgentRuntime.start_session(workspace, session_opts) do
      {:ok, session} ->
        case send_owned_session_runtime_info(
               codex_update_recipient,
               issue,
               session,
               registration_ack_required?(opts)
             ) do
          :ok ->
            try do
              result =
                do_run_codex_turns(session, issue, 1, %{
                  workspace: workspace,
                  codex_update_recipient: codex_update_recipient,
                  opts: opts,
                  issue_state_fetcher: issue_state_fetcher,
                  max_turns: max_turns,
                  worker_host: worker_host,
                  ownership_env: ownership_env
                })

              if destructive_stop_blocked?(result) do
                Logger.error(
                  "Preserving delegated runtime session for #{issue_context(issue)}: work-preservation checkpoint failed, destructive shutdown is blocked; recover via the owned session reference"
                )

                result
              else
                stop_session_result(session, result)
              end
            catch
              kind, reason ->
                case AgentRuntime.stop_session(session) do
                  :ok ->
                    :erlang.raise(kind, reason, __STACKTRACE__)

                  {:error, cleanup_reason} ->
                    exit({:agent_runtime_failed, {:owned_session_cleanup_failed, cleanup_reason}})
                end
            end

          {:error, reason} ->
            session
            |> stop_session_result({:error, reason})
            |> finish_with_after_run_hook(
              workspace,
              issue,
              worker_host,
              ownership_env
            )
        end

      result ->
        finish_start_result(result, %{
          recipient: codex_update_recipient,
          issue: issue,
          registration_ack_required?: registration_ack_required?(opts),
          workspace: workspace,
          worker_host: worker_host,
          ownership_env: ownership_env
        })
    end
  end

  defp stop_session_result(session, result) do
    case AgentRuntime.stop_session(session) do
      :ok -> result
      {:error, reason} -> {:error, {:owned_session_cleanup_failed, reason}}
    end
  end

  # A typed preservation failure forbids destroying the live pane/session; the
  # owned session reference already sent to the recipient stays recoverable.
  defp destructive_stop_blocked?({:error, reason}), do: checkpoint_blocked?(reason)
  defp destructive_stop_blocked?(_result), do: false

  defp checkpoint_blocked?({:implementer_checkpoint_failed, %{destructive_shutdown_blocked: true}}), do: true

  defp checkpoint_blocked?({_tag, %{checkpoint: {:error, inner}}}), do: checkpoint_blocked?(inner)

  defp checkpoint_blocked?({_tag, _detail, %{checkpoint: {:error, inner}}}), do: checkpoint_blocked?(inner)

  defp checkpoint_blocked?(_reason), do: false

  defp send_owned_session_runtime_info(recipient, %Issue{id: issue_id}, session, true)
       when is_binary(issue_id) and is_pid(recipient) do
    case AgentRuntime.owned_session_ref(session) do
      ownership_ref when is_map(ownership_ref) ->
        ack_ref = make_ref()

        send(
          recipient,
          {:owned_session_runtime_info, issue_id, ownership_ref, self(), ack_ref}
        )

        receive do
          {:owned_session_runtime_info_ack, ^ack_ref} ->
            :ok
        after
          @owned_session_registration_timeout_ms ->
            {:error, {:owned_session_registration_failed, :ack_timeout}}
        end

      _ ->
        :ok
    end
  end

  defp send_owned_session_runtime_info(recipient, %Issue{id: issue_id}, session, false)
       when is_binary(issue_id) and is_pid(recipient) do
    case AgentRuntime.owned_session_ref(session) do
      ownership_ref when is_map(ownership_ref) ->
        send(recipient, {:owned_session_runtime_info, issue_id, ownership_ref})
        :ok

      _ ->
        :ok
    end
  end

  defp send_owned_session_runtime_info(_recipient, _issue, _session, _ack_required), do: :ok

  defp finish_start_result(
         {:error, {:herdr_agent_not_ready, %{owned_session_ref: ownership_ref}}} = result,
         context
       )
       when is_map(ownership_ref),
       do: finish_blocked_startup(result, ownership_ref, context)

  defp finish_start_result(result, context) do
    finish_with_after_run_hook(
      result,
      context.workspace,
      context.issue,
      context.worker_host,
      context.ownership_env
    )
  end

  defp finish_blocked_startup(result, ownership_ref, context) do
    case send_owned_session_runtime_info_ref(
           context.recipient,
           context.issue,
           ownership_ref,
           context.registration_ack_required?
         ) do
      :ok ->
        finish_with_after_run_hook(
          result,
          context.workspace,
          context.issue,
          context.worker_host,
          context.ownership_env
        )

      {:error, reason} ->
        failure = cleanup_after_registration_failure(ownership_ref, reason)

        finish_with_after_run_hook(
          {:error, failure},
          context.workspace,
          context.issue,
          context.worker_host,
          context.ownership_env
        )
    end
  end

  defp cleanup_after_registration_failure(ownership_ref, registration_reason) do
    case AgentRuntime.cleanup_owned_session(ownership_ref) do
      :ok -> registration_reason
      {:error, cleanup_reason} -> {:owned_session_cleanup_failed, cleanup_reason}
    end
  end

  defp send_owned_session_runtime_info_ref(recipient, %Issue{id: issue_id}, ownership_ref, true)
       when is_binary(issue_id) and is_pid(recipient) and is_map(ownership_ref) do
    ack_ref = make_ref()
    send(recipient, {:owned_session_runtime_info, issue_id, ownership_ref, self(), ack_ref})

    receive do
      {:owned_session_runtime_info_ack, ^ack_ref} -> :ok
    after
      @owned_session_registration_timeout_ms ->
        {:error, {:owned_session_registration_failed, :ack_timeout}}
    end
  end

  defp send_owned_session_runtime_info_ref(recipient, %Issue{id: issue_id}, ownership_ref, false)
       when is_binary(issue_id) and is_pid(recipient) and is_map(ownership_ref) do
    send(recipient, {:owned_session_runtime_info, issue_id, ownership_ref})
    :ok
  end

  defp send_owned_session_runtime_info_ref(_recipient, _issue, _ownership_ref, _ack_required), do: :ok

  defp registration_ack_required?(opts), do: is_map(Keyword.get(opts, :process_ownership))

  defp put_optional(opts, _key, nil), do: opts
  defp put_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp do_run_codex_turns(
         app_session,
         issue,
         turn_number,
         %{
           workspace: workspace,
           codex_update_recipient: codex_update_recipient,
           opts: opts,
           issue_state_fetcher: issue_state_fetcher,
           max_turns: max_turns,
           worker_host: worker_host,
           ownership_env: ownership_env
         } = turn_context
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    turn_opts =
      opts
      |> Keyword.take(@delegation_turn_option_keys)
      |> Keyword.put(:on_message, codex_message_handler(codex_update_recipient, issue))

    turn_result =
      AgentRuntime.run_turn(
        app_session,
        prompt,
        issue,
        turn_opts
      )

    case finish_with_after_run_hook(
           turn_result,
           workspace,
           issue,
           worker_host,
           ownership_env
         ) do
      {:ok, {next_session, turn_session}} ->
        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_codex_turns(
              next_session,
              refreshed_issue,
              turn_number + 1,
              turn_context
            )

          {:continue, refreshed_issue} ->
            Logger.error("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; recording a typed failed run")

            {:error,
             {:max_turns_exhausted,
              %{
                issue_id: refreshed_issue.id,
                turn: turn_number,
                max_turns: max_turns
              }}}

          {:done, _refreshed_issue} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      result ->
        result
    end
  end

  defp finish_with_after_run_hook(
         result,
         workspace,
         issue,
         worker_host,
         ownership_env
       ) do
    case Workspace.run_after_run_hook(
           workspace,
           issue,
           worker_host,
           ownership_env
         ) do
      :ok -> result
      {:error, reason} -> post_turn_routing_result(result, issue, reason)
    end
  end

  # A failing post-turn routing hook must not re-open a run the runtime already
  # typed irrecoverable. Replacing that reason with the hook's own would send an
  # irrecoverable failure back through retry under the wrong family, which is
  # exactly the "runtime evidence, not agent judgement" property the typed
  # classification exists to hold. The hook failure is still recorded.
  defp post_turn_routing_result({:error, primary_reason} = result, issue, hook_reason) do
    case AgentRuntime.classify_failure(primary_reason, runner_failure_context(issue)) do
      {:irrecoverable, _failure} ->
        Logger.error(
          "Post-turn routing hook failed for #{issue_context(issue)} after an irrecoverable runtime failure: " <>
            "#{AgentRuntime.sanitize_runtime_text(inspect(hook_reason))}; preserving the irrecoverable reason"
        )

        result

      {:retryable, _failure} ->
        {:error, {:post_turn_routing_failed, hook_reason}}
    end
  end

  defp post_turn_routing_result(_result, _issue, hook_reason) do
    {:error, {:post_turn_routing_failed, hook_reason}}
  end

  defp process_ownership_environment(issue, opts) do
    case Keyword.get(opts, :process_ownership) do
      ownership when is_map(ownership) ->
        expected = %{
          role: Map.get(ownership, :role),
          run_id: Map.get(ownership, :run_id),
          holder: Map.get(ownership, :holder),
          workspace_path: Map.get(ownership, :workspace_path)
        }

        case ProcessOwnership.verify(issue, expected) do
          {:ok, verified} -> {:ok, ProcessOwnership.ownership_env(issue, verified)}
          {:error, reason} -> {:error, {:process_ownership_publication_failed, reason}}
        end

      _ ->
        {:error, {:process_ownership_publication_failed, :ownership_missing}}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp runner_failure_context(%Issue{id: issue_id}) do
    %{
      issue_id: issue_id,
      role: ProcessOwnership.current_role(),
      provider: AgentRuntime.provider()
    }
  end
end
