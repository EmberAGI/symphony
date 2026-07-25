defmodule SymphonyElixir.ImplementerWorkerChannelRecordingTest do
  use ExUnit.Case, async: false

  @moduledoc """
  RED: the recorder only sees one spelling of the command it is recording.

  The generated role `herdr` shim decides whether a command is a worker prompt
  with `[ "$1" = "agent" ] && [ "$2" = "prompt" ]`. Herdr accepts its global
  options before the subcommand, and `--session <name>` is the form Symphony's
  own `command/3` builds and the form the generated `launch-worker` script
  uses. An orchestrator that spells the delegation
  `herdr --session <name> agent prompt implementer_worker "<message>"` shifts
  `$1` to `--session`, so the shim falls through to `exec` on the real binary:
  the prompt is delivered, the exit status is 0, and nothing is recorded.

  Canary EMB-1284 delegated three `OCTO_MSG/1 kind=assignment` envelopes over
  two `agent prompt implementer_worker` invocations and produced no correlation
  event. Nothing surfaced because the miss is invisible from both sides — the
  orchestrator saw success and Symphony saw a run that never delegated.

  These tests pin the recorder against the command forms Herdr actually
  accepts, and pin the runtime against silently completing a run whose
  delegation it could not observe.
  """

  alias SymphonyElixir.ImplementerDelegation.HerdrTransport
  alias SymphonyElixir.TestSupport.HerdrReplayFixture

  setup do
    root = Path.join(System.tmp_dir!(), "iwcr-#{System.unique_integer([:positive])}")
    provider_bin = Path.join(root, "provider-bin")
    workspace = Path.join(root, "selected-product")

    File.mkdir_p!(provider_bin)
    File.mkdir_p!(workspace)

    for provider <- ["codex", "claude"] do
      fake = Path.join(provider_bin, provider)
      File.write!(fake, "#!/bin/sh\nexit 0\n")
      File.chmod!(fake, 0o755)
    end

    previous_path = System.get_env("PATH") || ""
    System.put_env("PATH", provider_bin <> ":" <> previous_path)

    herdr_bin = Path.join(root, "fake-herdr")
    herdr_log = Path.join(root, "herdr.log")
    replay_dir = Path.join(root, "herdr-replay")
    HerdrReplayFixture.materialize_replay_dir!(replay_dir)
    HerdrReplayFixture.write_fake_herdr!(herdr_bin, replay_dir)

    runtime_root = Path.join(System.tmp_dir!(), "iwcr-rt-#{System.unique_integer([:positive])}")

    context = %{
      herdr_bin: herdr_bin,
      extra_env: [{"HERDR_FAKE_LOG", herdr_log}],
      socket_root: runtime_root,
      poll_interval_ms: 5,
      start_timeout_ms: 2_000
    }

    assert {:ok, session} =
             HerdrTransport.start_session(
               %{name: "octo-emb-1284-channel", isolated: true, workspace: workspace, env: %{}},
               context
             )

    # The shims are materialized before the worker prestart, which needs a
    # launchable pane the replay fixture does not provide here.
    _ = HerdrTransport.prepare_worker(session, worker_spec(workspace), context)

    # `stop_session/2` awaits the server Task from its owner process, which the
    # `on_exit` process is not. The run-owned server is stopped over the same
    # CLI seam instead.
    on_exit(fn ->
      System.put_env("PATH", previous_path)

      _ =
        System.cmd(herdr_bin, ["--session", session.name, "server", "stop"],
          env: [{"HERDR_FAKE_LOG", herdr_log}, {"XDG_CONFIG_HOME", runtime_root}],
          stderr_to_stdout: true
        )

      File.rm_rf(root)
      File.rm_rf(runtime_root)
    end)

    {:ok, session: session, runtime_root: runtime_root, shim_env: [{"HERDR_FAKE_LOG", herdr_log}, {"XDG_CONFIG_HOME", runtime_root}]}
  end

  @assignment "OCTO_MSG/1 kind=assignment assignment=EMB1284-EVIDENCE-9C21 deliverable=bounded"
  @result "OCTO_MSG/1 kind=result assignment=EMB1284-EVIDENCE-9C21 status=completed"

  describe "the orchestrator shim records a worker prompt however Herdr spells it" do
    test "the bare subcommand form", context do
      assert {0, %{delivery: 1, assignment: 1}} =
               orchestrator(context, ["agent", "prompt", "implementer_worker", @assignment])
    end

    test "the global --session form the launcher itself uses", context do
      assert {0, %{delivery: 1, assignment: 1}} =
               orchestrator(context, [
                 "--session",
                 context.session.name,
                 "agent",
                 "prompt",
                 "implementer_worker",
                 @assignment
               ])
    end

    test "a --session passed after the subcommand", context do
      assert {0, %{delivery: 1, assignment: 1}} =
               orchestrator(context, [
                 "agent",
                 "prompt",
                 "--session",
                 context.session.name,
                 "implementer_worker",
                 @assignment
               ])
    end

    test "a caller that supplies its own settle flags", context do
      assert {0, %{delivery: 1, assignment: 1}} =
               orchestrator(context, [
                 "agent",
                 "prompt",
                 "implementer_worker",
                 @assignment,
                 "--wait",
                 "--until",
                 "idle"
               ])
    end

    test "a plain delegation with no envelope is still a recorded delivery", context do
      assert {0, %{delivery: 1, assignment: 0}} =
               orchestrator(context, [
                 "--session",
                 context.session.name,
                 "agent",
                 "prompt",
                 "implementer_worker",
                 "EMB1284-EVIDENCE-9C21: produce the bounded deliverable"
               ])
    end

    test "commands that are not worker prompts record nothing", context do
      assert {0, %{delivery: 0, assignment: 0, unparsed: 0}} =
               orchestrator(context, ["--session", context.session.name, "agent", "get", "implementer_worker"])
    end
  end

  describe "the worker shim answers over the same spellings" do
    test "the bare subcommand form", context do
      assert {0, %{reply: 1, result: 1}} =
               worker(context, ["agent", "prompt", "implementer_orchestrator", @result])
    end

    test "the global --session form", context do
      assert {0, %{reply: 1, result: 1}} =
               worker(context, [
                 "--session",
                 context.session.name,
                 "agent",
                 "prompt",
                 "implementer_orchestrator",
                 @result
               ])
    end

    test "worker authority still denies a non-delegation command behind a global option", context do
      assert {64, _events} =
               worker(context, ["--session", context.session.name, "agent", "start", "descendant"])
    end
  end

  describe "a command form the recorder cannot classify is reported, not ignored" do
    test "an unmodelled global option before a worker prompt records an unparsed marker", context do
      assert {_status, %{delivery: 0, unparsed: 1}} =
               orchestrator(context, [
                 "--unmodelled-global",
                 "value",
                 "agent",
                 "prompt",
                 "implementer_worker",
                 @assignment
               ])
    end

    test "an unmodelled global option on an unrelated command records nothing", context do
      assert {_status, %{delivery: 0, unparsed: 0}} =
               orchestrator(context, ["--unmodelled-global", "value", "agent", "get", "implementer_worker"])
    end

    test "an unparsed worker prompt makes the whole assignment set unobservable", context do
      assert {_status, %{unparsed: 1}} =
               orchestrator(context, [
                 "--unmodelled-global",
                 "value",
                 "agent",
                 "prompt",
                 "implementer_worker",
                 @assignment
               ])

      assert {:error, {:worker_assignments_unobservable, %{reason: :unrecognized_herdr_command_form, unparsed: 1}}} =
               HerdrTransport.worker_assignments(context.session, %{})
    end
  end

  test "a worker reply with no recorded delivery is a typed gap, not an empty run", context do
    assert {0, %{reply: 1}} = worker(context, ["agent", "prompt", "implementer_orchestrator", "artifact written"])

    assert {:ok, [%{assignment_id: nil, status: :delivery_unrecorded, evidence: :channel}]} =
             HerdrTransport.worker_assignments(context.session, %{})
  end

  defp orchestrator(context, argv),
    do: run_shim(Path.join([context.runtime_root, "orchestrator-bin", "herdr"]), context, argv)

  defp worker(context, argv),
    do: run_shim(Path.join([context.runtime_root, "worker-bin", "herdr"]), context, argv)

  defp run_shim(shim, context, argv) do
    events = Path.join(context.runtime_root, "worker-events")
    for stale <- Path.wildcard(Path.join(events, "*")), do: File.rm_rf(stale)

    {_output, status} = System.cmd(shim, argv, env: context.shim_env, stderr_to_stdout: true)

    counts =
      Map.new(~w(delivery assignment reply result unparsed), fn prefix ->
        {String.to_atom(prefix), events |> Path.join(prefix <> ".*") |> Path.wildcard() |> length()}
      end)

    {status, counts}
  end

  defp worker_spec(workspace) do
    %{
      name: "implementer_worker",
      role: :worker,
      provider: "codex",
      cwd: workspace,
      argv: ["codex", "--model", "gpt-5.6-sol"],
      env: %{}
    }
  end
end
