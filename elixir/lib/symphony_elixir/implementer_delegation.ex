defmodule SymphonyElixir.ImplementerDelegation do
  @moduledoc """
  Owns one isolated Herdr session for an Implementer orchestrator and its workers.

  Callers provide the validated orchestrator/worker contract. This module derives the
  run-owned session name and exact orchestrator launcher, orders lifecycle operations,
  and proves cleanup did not replace or stop the operator's default Herdr
  server. Herdr command mechanics remain behind the transport seam.
  """

  require Logger

  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer
  alias SymphonyElixir.ImplementationEffort
  alias SymphonyElixir.ImplementerDelegation.Supervision

  @max_session_name_bytes 44
  @session_name_digest_chars 16

  # After supervision reports completion, `run_turn/4` still owes its terminal
  # evidence before teardown: the agent-output read and the worker-assignment
  # read. Each is a bounded transport read governed by the same status-read
  # timeout, so the allowance is expressed in those reads rather than as a
  # separate tuned number.
  @terminal_evidence_reads 2

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
    orchestrator_env = Keyword.get(opts, :orchestrator_env, %{})
    skill_execution_contracts = Keyword.get(opts, :skill_execution_contracts, [])
    permission_read_roots = SymphonyElixir.SkillExecutionContract.read_paths(skill_execution_contracts)

    with :ok <- validate_workspace(workspace),
         :ok <- validate_orchestrator_env(orchestrator_env),
         session_env =
           Map.put(
             orchestrator_env,
             "SYMPHONY_SKILL_EXECUTION_CONTRACTS",
             SymphonyElixir.SkillExecutionContract.encode!(skill_execution_contracts)
           ),
         {:ok, contract} <- ImplementationEffort.validate_runtime_contract(contract),
         {:ok, name} <- session_name(opts),
         {:ok, default_server_before} <- transport.default_server_snapshot(transport_context),
         {:ok, herdr_session} <-
           transport.start_session(
             %{
               name: name,
               isolated: true,
               workspace: workspace,
               env: session_env
             },
             transport_context
           ),
         herdr_session =
           herdr_session
           |> Map.put(:session_env, session_env)
           |> Map.put(:permission_read_roots, permission_read_roots)
           |> Map.put(:skill_execution_contracts, skill_execution_contracts),
         {:ok, herdr_session} <-
           prepare_worker(
             transport,
             transport_context,
             herdr_session,
             worker_spec(contract, workspace, herdr_session)
           ),
         {:ok, orchestrator} <-
           start_orchestrator(transport, transport_context, herdr_session, workspace, contract, orchestrator_env) do
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

  @doc false
  @spec skill_execution_projection_for_test(String.t(), list()) :: map()
  def skill_execution_projection_for_test("codex", contracts),
    do: CodexAppServer.skill_execution_projection_for_test(contracts)

  def skill_execution_projection_for_test("claude_code", contracts),
    do: ClaudeAppServer.skill_execution_projection_for_test(contracts)

  @doc """
  Bounded evidence allowance a routed turn still owes after supervision
  completes, derived from the number of terminal transport reads.
  """
  @spec terminal_evidence_allowance_ms(pos_integer()) :: pos_integer()
  def terminal_evidence_allowance_ms(status_read_timeout_ms)
      when is_integer(status_read_timeout_ms) and status_read_timeout_ms > 0 do
    @terminal_evidence_reads * status_read_timeout_ms
  end

  @doc """
  Longest a routed Implementer turn can still legitimately be running before an
  outside observer may treat it as stuck.

  The Implementer performs its own In Progress -> Agent Review handoff from
  inside its turn, so the orchestrator sees the downstream state while the turn
  is still live. From that instant the turn owes, at worst, the remainder of
  one normal supervision observation cycle plus its terminal evidence path
  (output read, worker-assignment read/validation, correlation outcome,
  completion event, post-turn gates, teardown).

  A bound at or under one observation cycle expires inside a window the
  supervisor was always going to spend, killing the turn before it can emit its
  correlation outcome (EMB-1306). Deriving the bound from the cadence keeps the
  two from drifting apart: raising the heartbeat interval raises this with it.
  """
  @spec handoff_settlement_bound_ms(pos_integer(), pos_integer()) :: pos_integer()
  def handoff_settlement_bound_ms(heartbeat_interval_ms, status_read_timeout_ms) do
    Supervision.observation_cycle_ms(heartbeat_interval_ms, status_read_timeout_ms) +
      terminal_evidence_allowance_ms(status_read_timeout_ms)
  end

  @spec default_handoff_settlement_bound_ms() :: pos_integer()
  def default_handoff_settlement_bound_ms do
    handoff_settlement_bound_ms(
      Supervision.default_heartbeat_interval_ms(),
      Supervision.default_status_read_timeout_ms()
    )
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          transport: transport,
          transport_context: transport_context,
          herdr_session: herdr_session,
          orchestrator: orchestrator
        } = session,
        prompt,
        issue,
        opts
      )
      when is_binary(prompt) and prompt != "" and is_list(opts) do
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, 3_600_000)
    start_timeout_ms = Keyword.get(opts, :start_timeout_ms, 120_000)
    heartbeat_interval_ms = Keyword.get(opts, :heartbeat_interval_ms, Supervision.default_heartbeat_interval_ms())
    status_read_timeout_ms = Keyword.get(opts, :status_read_timeout_ms, Supervision.default_status_read_timeout_ms())
    on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)

    with {:ok, worker_observation} <-
           begin_worker_assignment_observation(
             transport,
             herdr_session,
             status_read_timeout_ms,
             transport_context
           ),
         {:ok, turn_start} <-
           begin_turn(
             transport,
             transport_context,
             herdr_session,
             orchestrator,
             prompt,
             start_timeout_ms
           ),
         observed = turn_start.agent,
         :ok <-
           emit_started(
             on_message,
             herdr_session,
             orchestrator,
             observed,
             Map.get(session, :contract, %{})
           ),
         {:ok, completed} <-
           (case turn_start.phase do
              :completed ->
                {:ok, observed}

              :working ->
                supervise_working(
                  %{
                    transport: transport,
                    context: transport_context,
                    session: herdr_session,
                    orchestrator: orchestrator,
                    hard_budget_ms: turn_timeout_ms,
                    interval_ms: max(1, heartbeat_interval_ms),
                    status_read_timeout_ms: status_read_timeout_ms,
                    max_indeterminate_reads: Keyword.get(opts, :max_indeterminate_reads, 4),
                    stale_working_ms: Keyword.get(opts, :stale_working_ms, 900_000),
                    max_recovery_attempts: Keyword.get(opts, :max_recovery_attempts, 2),
                    settle_window_ms: Keyword.get(opts, :settle_window_ms, Supervision.default_settle_window_ms()),
                    on_message: on_message,
                    contract: Map.get(session, :contract, %{})
                  },
                  observed
                )
            end),
         {:ok, read} <-
           transport.read_agent(
             herdr_session,
             orchestrator,
             %{source: :recent_unwrapped, lines: 240},
             transport_context
           ),
         response = Map.get(read, :text, ""),
         :ok <- terminal_turn_status(contract_provider(Map.get(session, :contract, %{}), :orchestrator), response),
         {:ok, worker_assignments} <-
           worker_assignments(
             transport,
             herdr_session,
             worker_observation,
             transport_context
           ),
         :ok <- validate_worker_assignments(worker_assignments, herdr_session) do
      # Herdr's terminal `agent get` response may omit `agent_session` even
      # though the acknowledged prompt response carried it. Preserve the
      # provider session identity from that first observation so the durable
      # correlation outcome remains joinable after supervision settles.
      session_id = agent_session_id(completed) || agent_session_id(observed)
      worker_assignments = observed_assignments(worker_assignments)
      worker_evidence = bounded_worker_evidence(worker_assignments)

      log_worker_correlation(issue, herdr_session, session_id, worker_evidence)

      emit_message(on_message, :turn_completed, %{
        provider: contract_provider(Map.get(session, :contract, %{}), :orchestrator),
        herdr_session: Map.get(herdr_session, :name),
        agent: Map.get(orchestrator, :name),
        agent_status: Map.get(completed, :agent_status),
        session_id: session_id,
        worker_assignments: worker_evidence
      })

      {:ok,
       %{
         session_id: session_id,
         agent_status: Map.get(completed, :agent_status),
         response: response,
         worker_assignments: worker_assignments
       }}
    end
  end

  def run_turn(_session, _prompt, _issue, _opts), do: {:error, :invalid_implementer_delegation_turn}

  defp begin_turn(transport, context, session, orchestrator, prompt, timeout_ms) do
    case transport.begin_turn(session, orchestrator, prompt, timeout_ms, context) do
      {:error, {:herdr_agent_blocked, _name}} ->
        # A prompt that settles blocked is preserved with the same
        # evidence-shaped outcome supervision produces, so the runner's
        # checkpoint-gated shutdown decision applies before any teardown.
        Supervision.blocked_outcome(%{
          transport: transport,
          context: context,
          session: session,
          orchestrator: orchestrator
        })

      other ->
        other
    end
  end

  # A transport that cannot report assignments has not reported "no
  # assignments"; it has reported nothing. The two are kept apart here so the
  # caller decides, rather than inheriting an empty list it cannot distinguish.
  defp worker_assignments(transport, herdr_session, worker_observation, transport_context) do
    result =
      cond do
        function_exported?(transport, :worker_assignments, 3) and
            worker_observation != :legacy ->
          transport.worker_assignments(
            herdr_session,
            worker_observation,
            transport_context
          )

        function_exported?(transport, :worker_assignments, 2) ->
          transport.worker_assignments(herdr_session, transport_context)

        true ->
          {:error, {:worker_assignments_unobservable, %{reason: :transport_capability_missing, transport: transport}}}
      end

    case result do
      {:error, {:worker_assignments_unobservable, details}} ->
        {:ok, {:unobservable, details}}

      result ->
        result
    end
  end

  defp begin_worker_assignment_observation(transport, herdr_session, timeout_ms, transport_context) do
    if function_exported?(transport, :begin_worker_assignment_observation, 3) do
      case transport.begin_worker_assignment_observation(
             herdr_session,
             timeout_ms,
             transport_context
           ) do
        {:ok, observation} ->
          {:ok, observation}

        {:error, {:worker_assignments_unobservable, details}} ->
          {:error, {:implementer_worker_assignments_unobservable, details}}

        {:error, reason} ->
          {:error, {:implementer_worker_assignments_unobservable, %{reason: :worker_observation_failed, error: reason}}}
      end
    else
      {:ok, :legacy}
    end
  end

  # Unobservable is only benign where there is provably nothing to observe: a
  # session that never launched a worker. Once a worker agent is live in the
  # session, an unreadable assignment set fails typed instead of settling as an
  # empty one.
  defp validate_worker_assignments({:unobservable, details}, herdr_session) do
    if is_map(Map.get(herdr_session, :worker)),
      do: {:error, {:implementer_worker_assignments_unobservable, details}},
      else: :ok
  end

  defp validate_worker_assignments(assignments, _herdr_session) when is_list(assignments) do
    Enum.reduce_while(assignments, :ok, fn assignment, :ok ->
      case worker_assignment_result(assignment) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_worker_assignments(_assignments, _herdr_session),
    do: {:error, {:implementer_worker_result_missing, %{assignment_id: nil}}}

  defp observed_assignments({:unobservable, _details}), do: []
  defp observed_assignments(assignments) when is_list(assignments), do: assignments

  defp worker_assignment_result(%{status: :delivery_unrecorded}) do
    {:error, {:implementer_worker_delivery_unrecorded, %{assignment_id: nil}}}
  end

  # The channel proves the assignment was delivered and that the worker
  # answered it. It carries no success claim of the worker's own — only the
  # `OCTO_MSG` envelope does — so its result status says exactly that.
  defp worker_assignment_result(%{
         assignment_id: assignment_id,
         status: :completed,
         evidence: :channel,
         result: %{assignment_id: assignment_id, status: "returned"}
       })
       when is_binary(assignment_id) and assignment_id != "",
       do: :ok

  defp worker_assignment_result(%{
         assignment_id: assignment_id,
         status: :assignment_unrecorded,
         result: result
       }) do
    {:error, {:implementer_worker_assignment_unrecorded, %{assignment_id: assignment_id, result: result}}}
  end

  defp worker_assignment_result(%{
         assignment_id: assignment_id,
         status: :completed,
         result: %{assignment_id: assignment_id, status: "completed"}
       })
       when is_binary(assignment_id) and assignment_id != "",
       do: :ok

  defp worker_assignment_result(%{
         assignment_id: assignment_id,
         status: :completed,
         result: %{assignment_id: assignment_id} = result
       }) do
    {:error, {:implementer_worker_result_failed, %{assignment_id: assignment_id, result: result}}}
  end

  defp worker_assignment_result(%{
         assignment_id: assignment_id,
         status: :completed,
         result: %{assignment_id: observed_assignment_id}
       }) do
    {:error,
     {:implementer_worker_result_mismatch,
      %{
        assignment_id: assignment_id,
        observed_assignment_id: observed_assignment_id
      }}}
  end

  defp worker_assignment_result(%{
         assignment_id: assignment_id,
         status: :failed,
         result: result
       }) do
    {:error, {:implementer_worker_result_failed, %{assignment_id: assignment_id, result: result}}}
  end

  defp worker_assignment_result(%{
         assignment_id: assignment_id,
         status: :launch_failed,
         reason: reason
       }) do
    {:error, {:implementer_worker_launch_failed, %{assignment_id: assignment_id, reason: reason}}}
  end

  defp worker_assignment_result(%{
         assignment_id: assignment_id,
         status: :died,
         reason: reason
       }) do
    {:error, {:implementer_worker_died, %{assignment_id: assignment_id, reason: reason}}}
  end

  defp worker_assignment_result(%{assignment_id: assignment_id, status: :timed_out}) do
    {:error, {:implementer_worker_timed_out, %{assignment_id: assignment_id}}}
  end

  defp worker_assignment_result(%{assignment_id: assignment_id}) do
    {:error, {:implementer_worker_result_missing, %{assignment_id: assignment_id}}}
  end

  defp worker_assignment_result(_assignment) do
    {:error, {:implementer_worker_result_missing, %{assignment_id: nil}}}
  end

  defp bounded_worker_evidence(assignments) when is_list(assignments) do
    Enum.map(assignments, fn assignment ->
      %{
        assignment_id: Map.get(assignment, :assignment_id),
        status: Map.get(assignment, :status),
        evidence: Map.get(assignment, :evidence),
        result_assignment_id: get_in(assignment, [:result, :assignment_id]),
        result_status: get_in(assignment, [:result, :status])
      }
    end)
  end

  defp log_worker_correlation(issue, herdr_session, session_id, []) do
    Logger.info(
      "Implementer worker result correlation not required " <>
        "outcome=no_delegation " <>
        worker_correlation_context(issue, herdr_session, session_id) <>
        " worker_assignments=[]"
    )
  end

  defp log_worker_correlation(issue, herdr_session, session_id, worker_evidence) do
    Logger.info(
      "Implementer worker result correlated " <>
        "outcome=correlated " <>
        worker_correlation_context(issue, herdr_session, session_id) <>
        " worker_assignments=#{inspect(worker_evidence)}"
    )
  end

  defp worker_correlation_context(issue, herdr_session, session_id) do
    "issue_id=#{Map.get(issue, :id)} " <>
      "issue_identifier=#{Map.get(issue, :identifier)} " <>
      "session_id=#{session_id} " <>
      "herdr_session=#{Map.get(herdr_session, :name)}"
  end

  @spec stop_session(session()) :: :ok | {:error, term()}
  def stop_session(%{
        transport: transport,
        transport_context: transport_context,
        herdr_session: herdr_session,
        default_server_before: expected_default
      }) do
    with :ok <- transport.stop_session(herdr_session, transport_context),
         {:ok, actual_default} <- transport.default_server_snapshot(transport_context) do
      verify_default_server(expected_default, actual_default)
    end
  end

  def stop_session(_session), do: {:error, :invalid_implementer_delegation_session}

  @doc "Return the transport-owned cleanup capability for external cancellation and recovery."
  @spec owned_session_ref(session()) :: map() | nil
  def owned_session_ref(%{
        transport: transport,
        transport_context: transport_context,
        herdr_session: herdr_session
      }) do
    if function_exported?(transport, :owned_session_ref, 2) do
      case transport.owned_session_ref(herdr_session, transport_context) do
        ownership_ref when is_map(ownership_ref) ->
          Map.put(ownership_ref, :handoff_settlement, :implementer_turn)

        _other ->
          nil
      end
    else
      nil
    end
  end

  def owned_session_ref(_session), do: nil

  defp start_orchestrator(transport, transport_context, herdr_session, workspace, contract, orchestrator_env) do
    orchestrator_env =
      orchestrator_env
      |> Map.put("OCTO_HERDR_WORKER_LAUNCHER", Map.fetch!(herdr_session, :worker_launcher))
      |> Map.put(
        "SYMPHONY_SKILL_EXECUTION_CONTRACTS",
        SymphonyElixir.SkillExecutionContract.encode!(Map.get(herdr_session, :skill_execution_contracts, []))
      )
      |> project_orchestrator_herdr_path(herdr_session)

    spec = %{
      name: "implementer_orchestrator",
      role: :orchestrator,
      provider: contract_provider(contract, :orchestrator),
      profile: contract.orchestrator,
      cwd: workspace,
      argv:
        launcher_argv(
          contract_provider(contract, :orchestrator),
          contract.orchestrator,
          workspace,
          orchestrator_permission_session(herdr_session, orchestrator_env)
        ),
      env: orchestrator_env
    }

    case transport.start_agent(herdr_session, spec, transport_context) do
      {:ok, orchestrator} ->
        {:ok, orchestrator}

      {:error, reason} ->
        _ = transport.stop_session(herdr_session, transport_context)
        {:error, {:implementer_orchestrator_start_failed, reason}}
    end
  end

  defp validate_orchestrator_env(env) when is_map(env) do
    if Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end),
      do: :ok,
      else: {:error, :invalid_implementer_orchestrator_environment}
  end

  defp validate_orchestrator_env(_env), do: {:error, :invalid_implementer_orchestrator_environment}

  defp orchestrator_permission_session(herdr_session, orchestrator_env) do
    case Map.get(orchestrator_env, "SYMPHONY_ROLE_OWNERSHIP_PATH") do
      path when is_binary(path) and path != "" ->
        Map.update(
          herdr_session,
          :permission_read_roots,
          [path],
          &Enum.uniq([path | &1])
        )

      _ ->
        herdr_session
    end
  end

  defp project_orchestrator_herdr_path(env, %{orchestrator_bin: orchestrator_bin})
       when is_binary(orchestrator_bin) and orchestrator_bin != "" do
    inherited_path = Map.get(env, "PATH") || System.get_env("PATH") || ""
    Map.put(env, "PATH", orchestrator_bin <> ":" <> inherited_path)
  end

  defp project_orchestrator_herdr_path(env, _session), do: env

  defp prepare_worker(transport, transport_context, herdr_session, worker_spec) do
    case transport.prepare_worker(herdr_session, worker_spec, transport_context) do
      {:ok, prepared_session} ->
        {:ok, prepared_session}

      {:error, reason} ->
        _ = transport.stop_session(herdr_session, transport_context)
        {:error, {:implementer_worker_prepare_failed, reason}}
    end
  end

  defp supervise_working(_state, %{agent_status: status} = agent)
       when status in ["idle", "done"],
       do: {:ok, agent}

  defp supervise_working(state, %{agent_status: "working"} = observed_start) do
    Supervision.supervise(%{
      transport: state.transport,
      context: state.context,
      session: state.session,
      orchestrator: state.orchestrator,
      hard_budget_ms: state.hard_budget_ms,
      interval_ms: state.interval_ms,
      status_read_timeout_ms: state.status_read_timeout_ms,
      max_indeterminate_reads: state.max_indeterminate_reads,
      stale_working_ms: state.stale_working_ms,
      max_recovery_attempts: state.max_recovery_attempts,
      settle_window_ms: state.settle_window_ms,
      baseline_revision: Map.get(observed_start, :revision),
      on_heartbeat: fn observed ->
        emit_message(state.on_message, :turn_heartbeat, %{
          provider: contract_provider(state.contract, :orchestrator),
          herdr_session: Map.get(state.session, :name),
          agent: Map.get(state.orchestrator, :name),
          agent_status: Map.get(observed, :agent_status),
          session_id: nil
        })
      end
    })
  end

  defp supervise_working(_state, agent),
    do: {:error, {:unexpected_herdr_agent_status, Map.get(agent, :agent_status)}}

  defp emit_started(on_message, herdr_session, orchestrator, observed, contract) do
    emit_message(on_message, :session_started, %{
      provider: contract_provider(contract, :orchestrator),
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
         workspace,
         %{
           runtime_root: runtime_root,
           socket: socket,
           permission_read_roots: permission_read_roots
         }
       ) do
    [
      "codex",
      "--model",
      model,
      "--config",
      "check_for_update_on_startup=false",
      "--config",
      "model_reasoning_effort=#{effort}",
      "--config",
      "developer_instructions=#{config_value(instructions)}",
      "--config",
      "shell_environment_policy.inherit=all",
      "--config",
      "default_permissions=\"octo_herdr\"",
      "--config",
      codex_filesystem_permissions(runtime_root, permission_read_roots),
      "--config",
      "permissions.octo_herdr.network={enabled=true,unix_sockets={#{config_value(socket)}=\"allow\"}}",
      "--ask-for-approval",
      "never",
      "--disable",
      "multi_agent",
      "--dangerously-bypass-hook-trust",
      "--config",
      "projects={#{config_value(workspace)}={trust_level=\"trusted\"}}",
      "--no-alt-screen"
    ]
  end

  defp launcher_argv(
         "claude_code",
         %{model: model, reasoning_effort: effort, instructions: instructions},
         _workspace,
         herdr_session
       ) do
    skill_args =
      herdr_session
      |> Map.get(:skill_execution_contracts, [])
      |> ClaudeAppServer.skill_execution_projection_for_test()
      |> Map.fetch!(:args)

    [
      "claude",
      "--model",
      model,
      "--effort",
      effort,
      "--append-system-prompt",
      instructions
    ] ++
      skill_args ++
      [
        "--dangerously-skip-permissions",
        "--disallowed-tools",
        "Agent"
      ]
  end

  defp launcher_argv(provider, _profile, _workspace, _herdr_session),
    do: raise(ArgumentError, "unsupported Implementer provider #{inspect(provider)}")

  # Every Codex `--config` value is a TOML string, and a launch contract that
  # silently loses part of one is worse than a launch that fails. `inspect/1`
  # truncates a printable binary at its 4096-byte `:printable_limit` and
  # appends `<> ...`, which quietly dropped everything past that boundary in a
  # profile's instructions — the worker-assignment protocol included.
  defp config_value(value), do: inspect(value, printable_limit: :infinity, limit: :infinity)

  # The session runtime root stays read-only: the socket, the role Herdr
  # wrappers, the launch projections, and the launch acknowledgements are
  # evidence a sandboxed agent must not be able to rewrite.
  #
  # `<runtime_root>/worker-events` is the one exception. The role Herdr wrapper
  # records every observed delegation command by `mktemp`-ing a file there, and
  # that recorder runs from inside the real Codex tool sandbox. Without this
  # grant the recorder fails with `Read-only file system`, the run produces no
  # observation, and worker correlation fails closed with `no_delegation` even
  # though the orchestrator was healthy. A sandbox resolves a request against
  # the most specific matching grant, so the nested write applies to the
  # worker-events subtree only and leaves the rest of the root read-only.
  defp codex_filesystem_permissions(runtime_root, permission_read_roots) do
    read_roots =
      [runtime_root | permission_read_roots]
      |> Enum.uniq()
      |> Enum.map_join(",", &"#{config_value(&1)}=\"read\"")

    worker_events = config_value(worker_events_root(runtime_root))

    "permissions.octo_herdr.filesystem={\":minimal\"=\"read\",\":workspace_roots\"={\".\"=\"write\",\".git\"=\"write\"},#{read_roots},#{worker_events}=\"write\"}"
  end

  # Must stay the same directory `HerdrTransport` materializes and its role
  # Herdr wrappers record into; the real-sandbox smoke binds the two together.
  defp worker_events_root(runtime_root), do: Path.join(runtime_root, "worker-events")

  defp worker_spec(contract, workspace, herdr_session) do
    %{
      name: "implementer_worker",
      role: :worker,
      provider: contract_provider(contract, :worker),
      profile: contract.worker,
      cwd: workspace,
      argv: launcher_argv(contract_provider(contract, :worker), contract.worker, workspace, herdr_session),
      env:
        herdr_session
        |> Map.get(:session_env, %{})
        |> Map.put(
          "SYMPHONY_SKILL_EXECUTION_CONTRACTS",
          SymphonyElixir.SkillExecutionContract.encode!(Map.get(herdr_session, :skill_execution_contracts, []))
        ),
      may_spawn_agents: false
    }
  end

  defp contract_provider(contract, :orchestrator),
    do: Map.get(contract, :orchestrator_provider) || Map.get(contract, :provider)

  defp contract_provider(contract, :worker),
    do: Map.get(contract, :worker_provider) || Map.get(contract, :provider)

  defp terminal_turn_status("claude_code", response) when is_binary(response) do
    case Regex.run(
           ~r/API Error:\s*(401|403)\b[^\n]*(?:auth|credential|unauthor|forbidden)/i,
           response,
           capture: :all_but_first
         ) do
      [status] ->
        {:error,
         {:auth_failed,
          %{
            api_error_status: String.to_integer(status),
            subtype: "invalid_authentication_credentials"
          }}}

      nil ->
        if Regex.match?(~r/Please run \/login\b/i, response) do
          {:error, {:auth_failed, %{api_error_status: nil, subtype: "login_required"}}}
        else
          :ok
        end
    end
  end

  defp terminal_turn_status(_provider, _response), do: :ok

  defp session_name(opts) do
    with issue when is_binary(issue) and issue != "" <- Keyword.get(opts, :issue_identifier),
         run_id when is_binary(run_id) and run_id != "" <- Keyword.get(opts, :run_id) do
      issue_slug = slug(issue)

      "octo-#{issue_slug}-#{slug(run_id)}"
      |> compact_session_name(issue_slug)
      |> then(&{:ok, &1})
    else
      _ -> {:error, :missing_herdr_session_identity}
    end
  end

  defp compact_session_name(name, _issue_slug) when byte_size(name) <= @max_session_name_bytes, do: name

  defp compact_session_name(name, issue_slug) do
    digest =
      :sha256
      |> :crypto.hash(name)
      |> Base.encode16(case: :lower)
      |> binary_part(0, @session_name_digest_chars)

    max_prefix_bytes = @max_session_name_bytes - @session_name_digest_chars - 1
    readable_prefix = "octo-#{issue_slug}"
    prefix_bytes = min(byte_size(readable_prefix), max_prefix_bytes)

    prefix =
      readable_prefix
      |> binary_part(0, prefix_bytes)
      |> String.trim_trailing("-")

    "#{prefix}-#{digest}"
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
