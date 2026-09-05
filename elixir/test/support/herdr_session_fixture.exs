defmodule SymphonyElixir.TestSupport.HerdrSessionFixture do
  @moduledoc "Test-scoped ownership of sessions created through AgentRuntime."

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.ImplementerDelegation.HerdrTransport

  def start_transport_session(spec, context) do
    case HerdrTransport.start_session(spec, context) do
      {:ok, session} = result ->
        ownership = HerdrTransport.owned_session_ref(session, context)
        ExUnit.Callbacks.on_exit(fn -> :ok = HerdrTransport.cleanup_owned_session(ownership) end)
        result

      error ->
        error
    end
  end

  def start_session(workspace, opts) do
    case AgentRuntime.start_session(workspace, opts) do
      {:ok, session} = result ->
        ownership = AgentRuntime.owned_session_ref(session)

        ExUnit.Callbacks.on_exit(fn ->
          :ok = AgentRuntime.cleanup_owned_session(ownership)
        end)

        result

      error ->
        error
    end
  end
end
