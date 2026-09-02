defmodule SymphonyElixir.ImplementerDelegation.Transport do
  @moduledoc """
  Transport seam used internally by `SymphonyElixir.ImplementerDelegation`.

  The production adapter controls isolated Herdr sessions. Deterministic tests
  use an in-memory adapter and exercise the same lifecycle interface.
  """

  @type context :: term()
  @type server_snapshot :: %{
          required(:status) => String.t(),
          optional(:version) => String.t(),
          optional(:protocol) => integer(),
          required(:socket) => String.t()
        }
  @type session_ref :: map()
  @type agent_ref :: map()

  @callback default_server_snapshot(context()) :: {:ok, server_snapshot()} | {:error, term()}
  @callback start_session(map(), context()) :: {:ok, session_ref()} | {:error, term()}
  @callback prepare_worker(session_ref(), map(), context()) ::
              {:ok, session_ref()} | {:error, term()}
  @callback start_agent(session_ref(), map(), context()) :: {:ok, agent_ref()} | {:error, term()}
  @doc """
  Submit one verified prompt and observe how it settles.

  The effective prompt wait always exceeds Herdr v0.8.2's 5000 ms prompt-effect
  window (a smaller caller budget is raised to 5001 ms) so an unchanged
  `state_change_seq` is the typed `agent_prompt_stalled` result, never an
  ordinary timeout. A `blocked` settle is the typed blocked outcome, and an
  `unknown` observation is the typed unknown outcome — neither is success.
  """
  @callback begin_turn(session_ref(), agent_ref(), String.t(), non_neg_integer(), context()) ::
              {:ok, %{required(:phase) => :working | :completed, required(:agent) => agent_ref()}}
              | {:error, term()}
  @doc """
  Await a settled agent status with the server-owned wait.

  Callers must request exactly the upstream default settle set
  (`idle`, `done`, `blocked`); `blocked` settles as a typed non-success
  outcome and `unknown` never proves completion.
  """
  @callback await_agent(session_ref(), agent_ref(), [String.t()], non_neg_integer(), context()) ::
              {:ok, agent_ref()} | {:error, term()}
  @callback get_agent(session_ref(), agent_ref(), non_neg_integer(), context()) ::
              {:ok, agent_ref()} | {:error, term()}
  @callback read_agent(session_ref(), agent_ref(), map(), context()) :: {:ok, map()} | {:error, term()}
  @doc """
  Snapshot the authoritative worker state and recorder cursor before a turn.

  A transport implementing this callback must pair it with
  `worker_assignments/3`, which evaluates only evidence newer than the
  returned observation.
  """
  @callback begin_worker_assignment_observation(
              session_ref(),
              non_neg_integer(),
              context()
            ) :: {:ok, term()} | {:error, term()}
  @callback worker_assignments(session_ref(), context()) ::
              {:ok, [map()]} | {:error, term()}
  @callback worker_assignments(session_ref(), term(), context()) ::
              {:ok, [map()]} | {:error, term()}
  @callback stop_session(session_ref(), context()) :: :ok | {:error, term()}

  @optional_callbacks begin_worker_assignment_observation: 3,
                      worker_assignments: 2,
                      worker_assignments: 3
end
