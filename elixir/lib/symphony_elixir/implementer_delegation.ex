defmodule SymphonyElixir.ImplementerDelegation do
  @moduledoc """
  Owns one isolated Herdr session for an Implementer orchestrator and its workers.

  Callers provide the validated orchestrator/worker contract. This module derives the
  run-owned session name and exact orchestrator launcher, orders lifecycle operations,
  and proves cleanup did not replace or stop the operator's default Herdr
  server. Herdr command mechanics remain behind the transport seam.
  """

  alias SymphonyElixir.ImplementationEffort

  @type session :: %{
          required(:name) => String.t(),
          required(:contract) => map(),
          required(:transport) => module(),
          required(:transport_context) => term(),
          required(:herdr_session) => map(),
          required(:orchestrator) => map(),
          required(:default_server_before) => map()
        }

  @spec start_session(Path.t(), map(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, contract, opts) when is_binary(workspace) and is_map(contract) and is_list(opts) do
    transport = Keyword.fetch!(opts, :transport)
    transport_context = Keyword.get(opts, :transport_context, %{})

    with :ok <- validate_workspace(workspace),
         {:ok, contract} <- ImplementationEffort.validate_runtime_contract(contract),
         {:ok, name} <- session_name(opts),
         {:ok, default_server_before} <- transport.default_server_snapshot(transport_context),
         {:ok, herdr_session} <-
           transport.start_session(
             %{
               name: name,
               isolated: true,
               workspace: workspace,
               worker: worker_spec(contract, workspace)
             },
             transport_context
           ),
         {:ok, orchestrator} <-
           start_orchestrator(transport, transport_context, herdr_session, workspace, contract) do
      {:ok,
       %{
         runtime_adapter: __MODULE__,
         name: name,
         contract: contract,
         transport: transport,
         transport_context: transport_context,
         herdr_session: herdr_session,
         orchestrator: orchestrator,
         default_server_before: default_server_before
       }}
    end
  end

  def start_session(_workspace, _contract, _opts), do: {:error, :invalid_implementer_delegation_start}

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          transport: transport,
          transport_context: transport_context,
          herdr_session: herdr_session,
          orchestrator: orchestrator
        } = session,
        prompt,
        _issue,
        opts
      )
      when is_binary(prompt) and prompt != "" and is_list(opts) do
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, 3_600_000)
    start_timeout_ms = Keyword.get(opts, :start_timeout_ms, 30_000)
    on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)

    with :ok <- transport.submit(herdr_session, orchestrator, prompt, transport_context),
         {:ok, observed} <-
           transport.await_agent(
             herdr_session,
             orchestrator,
             ["working", "idle", "done"],
             start_timeout_ms,
             transport_context
           ),
         :ok <-
           emit_started(
             on_message,
             herdr_session,
             orchestrator,
             observed,
             Map.get(session, :contract, %{})
           ),
         {:ok, completed} <-
           await_completion(
             transport,
             transport_context,
             herdr_session,
             orchestrator,
             observed,
             turn_timeout_ms
           ),
         {:ok, read} <-
           transport.read_agent(
             herdr_session,
             orchestrator,
             %{source: :recent_unwrapped, lines: 240},
             transport_context
           ) do
      session_id = agent_session_id(completed)

      emit_message(on_message, :turn_completed, %{
        provider: get_in(session, [:contract, :provider]),
        herdr_session: Map.get(herdr_session, :name),
        agent: Map.get(orchestrator, :name),
        agent_status: Map.get(completed, :agent_status),
        session_id: session_id
      })

      {:ok,
       %{
         session_id: session_id,
         agent_status: Map.get(completed, :agent_status),
         response: Map.get(read, :text, "")
       }}
    end
  end

  def run_turn(_session, _prompt, _issue, _opts), do: {:error, :invalid_implementer_delegation_turn}

  @spec stop_session(session()) :: :ok | {:error, term()}
  def stop_session(%{
        transport: transport,
        transport_context: transport_context,
        herdr_session: herdr_session,
        default_server_before: expected_default
      }) do
    with :ok <- transport.stop_session(herdr_session, transport_context),
         {:ok, actual_default} <- transport.default_server_snapshot(transport_context),
         :ok <- verify_default_server(expected_default, actual_default) do
      :ok
    end
  end

  def stop_session(_session), do: {:error, :invalid_implementer_delegation_session}

  defp start_orchestrator(transport, transport_context, herdr_session, workspace, contract) do
    spec = %{
      name: "implementer_orchestrator",
      role: :orchestrator,
      provider: contract.provider,
      profile: contract.orchestrator,
      cwd: workspace,
      argv: launcher_argv(contract.provider, contract.orchestrator, workspace),
      env: %{"OCTO_HERDR_WORKER_LAUNCHER" => Map.fetch!(herdr_session, :worker_launcher)}
    }

    case transport.start_agent(herdr_session, spec, transport_context) do
      {:ok, orchestrator} ->
        ready_timeout_ms =
          if is_map(transport_context),
            do: Map.get(transport_context, :orchestrator_ready_timeout_ms, 30_000),
            else: 30_000

        case transport.await_agent(
               herdr_session,
               orchestrator,
               ["idle", "done"],
               ready_timeout_ms,
               transport_context
             ) do
          {:ok, ready_orchestrator} ->
            {:ok, ready_orchestrator}

          {:error, reason} ->
            _ = transport.stop_session(herdr_session, transport_context)
            {:error, {:implementer_orchestrator_ready_failed, reason}}
        end

      {:error, reason} ->
        _ = transport.stop_session(herdr_session, transport_context)
        {:error, {:implementer_orchestrator_start_failed, reason}}
    end
  end

  defp await_completion(_transport, _context, _session, _orchestrator, %{agent_status: status} = agent, _timeout_ms)
       when status in ["idle", "done"],
       do: {:ok, agent}

  defp await_completion(transport, context, session, orchestrator, %{agent_status: "working"}, timeout_ms) do
    transport.await_agent(session, orchestrator, ["idle", "done"], timeout_ms, context)
  end

  defp await_completion(_transport, _context, _session, _orchestrator, agent, _timeout_ms),
    do: {:error, {:unexpected_herdr_agent_status, Map.get(agent, :agent_status)}}

  defp emit_started(on_message, herdr_session, orchestrator, observed, contract) do
    emit_message(on_message, :session_started, %{
      provider: Map.get(contract, :provider),
      herdr_session: Map.get(herdr_session, :name),
      agent: Map.get(orchestrator, :name),
      agent_status: Map.get(observed, :agent_status),
      session_id: agent_session_id(observed)
    })
  end

  defp emit_message(on_message, event, details) when is_function(on_message, 1) do
    details
    |> Map.put(:event, event)
    |> Map.put(:timestamp, DateTime.utc_now())
    |> on_message.()

    :ok
  end

  defp launcher_argv(
         "codex",
         %{model: model, reasoning_effort: effort, instructions: instructions},
         workspace
       ) do
    [
      "codex",
      "--model",
      model,
      "--config",
      "model_reasoning_effort=#{effort}",
      "--config",
      "developer_instructions=#{inspect(instructions)}",
      "--config",
      "shell_environment_policy.inherit=all",
      "--sandbox",
      "workspace-write",
      "--ask-for-approval",
      "never",
      "--disable",
      "multi_agent",
      "--dangerously-bypass-hook-trust",
      "--config",
      "projects={#{inspect(workspace)}={trust_level=\"trusted\"}}",
      "--no-alt-screen"
    ]
  end

  defp launcher_argv(
         "claude_code",
         %{model: model, reasoning_effort: effort, instructions: instructions},
         _workspace
       ) do
    [
      "claude",
      "--model",
      model,
      "--effort",
      effort,
      "--append-system-prompt",
      instructions,
      "--dangerously-skip-permissions",
      "--disallowed-tools",
      "Agent"
    ]
  end

  defp launcher_argv(provider, _profile, _workspace),
    do: raise(ArgumentError, "unsupported Implementer provider #{inspect(provider)}")

  defp worker_spec(contract, workspace) do
    %{
      name: "implementer_worker",
      role: :worker,
      provider: contract.provider,
      profile: contract.worker,
      cwd: workspace,
      argv: launcher_argv(contract.provider, contract.worker, workspace),
      may_spawn_agents: false
    }
  end

  defp session_name(opts) do
    with issue when is_binary(issue) and issue != "" <- Keyword.get(opts, :issue_identifier),
         run_id when is_binary(run_id) and run_id != "" <- Keyword.get(opts, :run_id) do
      {:ok, "octo-#{slug(issue)}-#{slug(run_id)}"}
    else
      _ -> {:error, :missing_herdr_session_identity}
    end
  end

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp validate_workspace(workspace) do
    if Path.type(workspace) == :absolute,
      do: :ok,
      else: {:error, :implementer_delegation_workspace_not_absolute}
  end

  defp verify_default_server(expected, actual) do
    if Map.take(actual, [:status, :version, :protocol, :socket]) ==
         Map.take(expected, [:status, :version, :protocol, :socket]),
       do: :ok,
       else: {:error, {:default_herdr_server_changed, expected, actual}}
  end

  defp agent_session_id(%{agent_session: %{value: value}}) when is_binary(value), do: value
  defp agent_session_id(%{agent_session: %{"value" => value}}) when is_binary(value), do: value
  defp agent_session_id(_agent), do: nil
end
