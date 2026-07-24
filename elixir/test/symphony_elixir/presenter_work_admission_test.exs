defmodule SymphonyElixirWeb.PresenterWorkAdmissionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixirWeb.Presenter

  defmodule SnapshotServer do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot, name: __MODULE__)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  test "state payload fails closed when an older snapshot has no admission projection" do
    {:ok, pid} =
      SnapshotServer.start_link(%{
        running: [],
        retrying: [],
        blocked: [],
        codex_totals: %{},
        rate_limits: nil
      })

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert %{work_admission: %{status: "closed", target_generation: "unknown", drained: false}} =
             Presenter.state_payload(SnapshotServer, 1_000)
  end
end
