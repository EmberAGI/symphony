Code.require_file("../test_helper.exs", __DIR__)

defmodule SymphonyElixir.HerdrSessionTeardownProbe do
  use ExUnit.Case

  alias SymphonyElixir.{AgentRuntime, TestSupport}
  alias SymphonyElixir.ImplementerDelegation.HerdrTransport
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TestSupport.{HerdrReplayFixture, HerdrSessionFixture}

  @tag timeout: 15_000
  test "session lifecycle survives an assertion before explicit stop" do
    root = System.fetch_env!("TEARDOWN_PROBE_ROOT")
    fixture_root = Path.join(root, "fixtures")
    workspace = Path.join(fixture_root, "workspace")
    provider_bin = Path.join(fixture_root, "bin")
    File.mkdir_p!(workspace)
    File.mkdir_p!(provider_bin)

    for provider <- ["codex", "claude"] do
      path = Path.join(provider_bin, provider)
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o755)
    end

    System.put_env("PATH", provider_bin <> ":" <> System.fetch_env!("PATH"))
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")
    Application.put_env(:symphony_elixir, :delegation_transport_module, HerdrTransport)
    TestSupport.write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(), tracker_kind: "memory")
    replay = Path.join(fixture_root, "replay")
    HerdrReplayFixture.materialize_replay_dir!(replay)
    binary = Path.join(fixture_root, "fake-herdr")
    HerdrReplayFixture.write_fake_herdr!(binary, replay)
    on_exit(fn -> File.rm_rf!(fixture_root) end)

    issue = %Issue{
      id: "teardown-probe",
      identifier: "TUR-844",
      title: "Fixture teardown proof",
      state: "In Progress",
      repository: "EmberAGI/symphony",
      repository_source: "linear_label",
      labels: ["implementation-effort:moderate"]
    }

    context = %{
      herdr_bin: binary,
      socket_root: Path.join(root, "runtime"),
      extra_env: [
        {"HERDR_FAKE_LOG", Path.join(root, "commands")},
        {"HERDR_FAKE_SERVER_PID_FILE", Path.join(root, "pid")}
      ],
      start_timeout_ms: 2_000,
      poll_interval_ms: 5
    }

    transport? = System.get_env("TEARDOWN_PROBE_KIND") == "transport"

    {:ok, session} =
      if transport? do
        HerdrSessionFixture.start_transport_session(
          %{name: "octo-tur-844-teardown-probe", isolated: true, workspace: workspace},
          context
        )
      else
        HerdrSessionFixture.start_session(workspace,
          issue: issue,
          role: "implementer",
          run_id: "teardown-probe",
          delegation_transport_context: context
        )
      end

    runtime = if transport?, do: session.runtime_root, else: session.herdr_session.runtime_root
    File.write!(Path.join(root, "runtime-path"), runtime)

    if System.get_env("TEARDOWN_PROBE_OUTCOME") == "failure" do
      flunk("intentional teardown probe failure")
    else
      ownership = AgentRuntime.owned_session_ref(session)
      assert :ok = AgentRuntime.stop_session(session)
      assert :ok = AgentRuntime.cleanup_owned_session(ownership)
      assert :ok = AgentRuntime.cleanup_owned_session(ownership)
    end
  end
end
