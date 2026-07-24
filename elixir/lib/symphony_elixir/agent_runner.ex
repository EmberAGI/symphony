defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.{AgentRuntime, Config, Linear.Issue, PromptBuilder, Runtime.ProcessOwnership, Tracker, Workspace}

  @type worker_host :: String.t() | nil
  @owned_session_registration_timeout_ms 5_000

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
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
        finish_with_after_run_hook(
          result,
          workspace,
          issue,
          worker_host,
          ownership_env
        )
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

    turn_result =
      AgentRuntime.run_turn(
        app_session,
        prompt,
        issue,
        on_message: codex_message_handler(codex_update_recipient, issue)
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
      {:error, reason} -> {:error, {:post_turn_routing_failed, reason}}
    end
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
