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
  @callback start_agent(session_ref(), map(), context()) :: {:ok, agent_ref()} | {:error, term()}
  @callback submit(session_ref(), agent_ref(), String.t(), context()) :: :ok | {:error, term()}
  @callback await_agent(session_ref(), agent_ref(), [String.t()], non_neg_integer(), context()) ::
              {:ok, agent_ref()} | {:error, term()}
  @callback read_agent(session_ref(), agent_ref(), map(), context()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session_ref(), context()) :: :ok | {:error, term()}
end
