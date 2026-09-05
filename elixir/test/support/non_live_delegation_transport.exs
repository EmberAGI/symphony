defmodule SymphonyElixir.TestSupport.NonLiveDelegationTransport do
  @moduledoc """
  Sealed implementer-delegation transport for the non-live gate.

  Installed as the suite-wide `:delegation_transport_module` default so a run
  that escapes its configured workflow (the EMB-1180 fall-through) fails
  immediately with a typed error at the first transport callback instead of
  launching a real herdr server, session, worker, or provider process. The
  module holds no state and spawns nothing; genuine delegation tests inject
  their own fake transport through the explicit `:delegation_transport`
  option, which always wins over this default.
  """

  @behaviour SymphonyElixir.ImplementerDelegation.Transport

  @impl true
  def default_server_snapshot(_context), do: sealed(:default_server_snapshot)

  @impl true
  def start_session(_spec, _context), do: sealed(:start_session)

  @impl true
  def prepare_worker(_session, _worker_spec, _context), do: sealed(:prepare_worker)

  @impl true
  def start_agent(_session, _agent_spec, _context), do: sealed(:start_agent)

  @impl true
  def begin_turn(_session, _agent, _prompt, _timeout_ms, _context), do: sealed(:begin_turn)

  @impl true
  def await_agent(_session, _agent, _statuses, _timeout_ms, _context), do: sealed(:await_agent)

  @impl true
  def get_agent(_session, _agent, _timeout_ms, _context), do: sealed(:get_agent)

  @impl true
  def read_agent(_session, _agent, _opts, _context), do: sealed(:read_agent)

  @impl true
  def owned_session_ref(_session, _context), do: nil

  @impl true
  def stop_session(_session, _context), do: :ok

  defp sealed(callback), do: {:error, {:non_live_delegation_transport, callback}}
end
