defmodule SymphonyElixir.ImplementerWorkerEventsPermissionTest do
  @moduledoc """
  EMB-1302: the projected Codex filesystem permission must let the role Herdr
  wrapper record worker observation events while the rest of the session
  runtime root stays read-only.

  Production evidence (EMB-1303): the wrapper's first act is
  `record_worker_event observed "$*"`, which `mktemp`s into
  `<runtime_root>/worker-events`. Inside the real Codex tool sandbox that write
  failed with `Read-only file system`, so the run produced no observation, the
  correlation fell to `outcome=no_delegation`, and the turn failed closed
  without ever delegating.

  These assertions resolve the projected grants the way a path sandbox does -
  most specific matching prefix wins - instead of matching the config string,
  so the contract survives any equivalent respelling of the projection.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.{ImplementationEffort, ImplementerDelegation}
  alias SymphonyElixir.Linear.Issue

  defmodule RecordingTransport do
    def default_server_snapshot(%{owner: owner}) do
      send(owner, {:transport, :default_server_snapshot})
      {:ok, %{status: "running", version: "0.8.2", protocol: 20, socket: "/tmp/operator-default/herdr.sock"}}
    end

    def start_session(spec, %{owner: owner}) do
      send(owner, {:transport, :start_session, spec})

      {:ok,
       %{
         name: spec.name,
         socket: "/tmp/#{spec.name}/herdr/sessions/#{spec.name}/herdr.sock",
         runtime_root: "/tmp/#{spec.name}"
       }}
    end

    def prepare_worker(session, spec, %{owner: owner}) do
      send(owner, {:transport, :prepare_worker, session, spec})

      {:ok,
       session
       |> Map.put(:worker_launcher, "/tmp/#{session.name}/launch-worker")
       |> Map.put(:orchestrator_bin, "/tmp/#{session.name}/orchestrator-bin")}
    end

    def start_agent(session, spec, %{owner: owner}) do
      send(owner, {:transport, :start_agent, session, spec})
      {:ok, %{name: spec.name, pane_id: "w1:p1", profile: spec.profile}}
    end
  end

  setup do
    assert {:ok, contract} =
             ImplementationEffort.runtime_profile_for_issue(:codex, issue(), "implementer")

    assert {:ok, _session} =
             ImplementerDelegation.start_session(
               "/tmp/emb-1302-workspace",
               contract,
               issue_identifier: "EMB-1302",
               run_id: "run-1302",
               transport: RecordingTransport,
               transport_context: %{owner: self()}
             )

    assert_receive {:transport, :prepare_worker, herdr_session, worker_spec}
    assert_receive {:transport, :start_agent, _session, orchestrator_spec}

    %{
      runtime_root: herdr_session.runtime_root,
      session_name: herdr_session.name,
      participants: [{"worker", worker_spec.argv}, {"orchestrator", orchestrator_spec.argv}]
    }
  end

  test "both Codex participants may write worker observations and nothing else under the runtime root",
       %{runtime_root: runtime_root, session_name: session_name, participants: participants} do
    worker_events = Path.join(runtime_root, "worker-events")

    for {role, argv} <- participants do
      grants = filesystem_grants(argv)

      assert effective_mode(grants, worker_events) == "write",
             "#{role}: the worker-events root must be writable so record_worker_event can create an observation"

      assert effective_mode(grants, Path.join(worker_events, "observed.000002.aBcDeF")) == "write",
             "#{role}: the mktemp'd observation file itself must be creatable"

      assert effective_mode(grants, runtime_root) == "read",
             "#{role}: the session runtime root itself must stay read-only"

      # Every other runtime path the transport materializes stays read-only:
      # the fix must not widen the socket, the wrappers, the launch
      # projections, or the launch acknowledgements.
      for sibling <- [
            Path.join([runtime_root, "herdr", "sessions", session_name, "herdr.sock"]),
            Path.join(runtime_root, "launch-worker"),
            Path.join(runtime_root, "launch-projections"),
            Path.join(runtime_root, "launch-acks"),
            Path.join(runtime_root, "orchestrator-bin"),
            Path.join(runtime_root, "worker-bin"),
            Path.join(runtime_root, "worker-panes"),
            Path.join(runtime_root, "pane-preflight"),
            Path.join(runtime_root, "worker-events-adjacent")
          ] do
        assert effective_mode(grants, sibling) == "read",
               "#{role}: #{sibling} must stay read-only"
      end

      assert Enum.filter(grants, fn {_path, mode} -> mode == "write" end) == [{worker_events, "write"}],
             "#{role}: worker-events is the only writable absolute grant"
    end
  end

  # Parses the projected `permissions.octo_herdr.filesystem` inline table into
  # its absolute-path grants. `:minimal` and `:workspace_roots` are relative
  # policy selectors, not runtime-root paths, so they are out of scope here.
  defp filesystem_grants(argv) do
    config =
      Enum.find(argv, fn arg ->
        is_binary(arg) and String.starts_with?(arg, "permissions.octo_herdr.filesystem=")
      end)

    assert is_binary(config), "the launch argv must project an octo_herdr filesystem permission"

    ~r/"(\/[^"]*)"="(read|write)"/
    |> Regex.scan(config, capture: :all_but_first)
    |> Enum.map(fn [path, mode] -> {path, mode} end)
  end

  # Path sandboxes resolve a request against the most specific matching grant.
  defp effective_mode(grants, path) do
    grants
    |> Enum.filter(fn {granted, _mode} -> granted == path or String.starts_with?(path, granted <> "/") end)
    |> Enum.max_by(fn {granted, _mode} -> String.length(granted) end, fn -> {nil, nil} end)
    |> elem(1)
  end

  defp issue do
    %Issue{
      id: "issue-1302",
      identifier: "EMB-1302",
      title: "Restore worker observation recording",
      state: "In Progress",
      branch_name: "sebastianvarela/emb-1302-restore-worker-observation",
      url: "https://linear.app/emberai/issue/EMB-1302",
      repository: "EmberAGI/symphony",
      repository_source: "linear_label",
      labels: ["implementation-effort:moderate"]
    }
  end
end
