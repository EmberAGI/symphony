defmodule SymphonyElixir.HerdrDifferentialTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.TestSupport.HerdrReplayFixture

  @moduledoc """
  CD-tier fake-vs-real differential harness (EMB-1244 AC 4a).

  Runs identical operations against the real herdr 0.8.2 binary and the
  replay-backed test double and fails on divergence, so no hand-authored
  behavior in the double survives without a differential check backing it.
  Opt-in only: requires `SYMPHONY_RUN_HERDR_DIFFERENTIAL=1` and a real herdr
  binary whose version matches the recorded fixtures. It is excluded from the
  non-live `make all` gate.
  """

  @moduletag :herdr_differential
  @moduletag timeout: 120_000

  # Gating is runtime-only: the :herdr_differential tag is excluded in
  # test_helper.exs unless SYMPHONY_RUN_HERDR_DIFFERENTIAL=1 is set for the
  # run. When the harness is explicitly requested, missing prerequisites fail
  # loudly instead of skipping.
  test "the replay double and the real binary agree on identical protocol operations" do
    real = System.find_executable("herdr")
    assert real, "the differential harness was requested but no real herdr binary is available"

    claude = System.find_executable("claude")

    assert claude,
           "the differential harness was requested but no real claude binary is available"

    assert match?({:unix, _}, :os.type()), "the differential fault injection requires POSIX process signals and ps"

    for key <- ~w(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN
                  CLAUDE_CODE_API_KEY_HELPER_FD CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
                  CLAUDE_CODE_USE_FOUNDRY CLIPROXYAPI_API_KEY OPENAI_API_KEY) do
      credential_absent? = System.get_env(key) in [nil, ""]
      assert credential_absent?, "anonymous differential requires #{key} to be unset"
    end

    {version_output, 0} = System.cmd(real, ["--version"])

    assert String.trim(version_output) == "herdr 0.8.2",
           "differential harness requires the pinned real herdr 0.8.2"

    root = Path.join(System.tmp_dir!(), "herdr-diff-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, "ws"))
    File.mkdir_p!(Path.join(root, "herdr"))

    File.write!(Path.join(root, "herdr/config.toml"), """
    [update]
    version_check = false
    manifest_check = false
    """)

    fake = Path.join(root, "fake-herdr")
    replay_dir = HerdrReplayFixture.materialize_replay_dir!(Path.join(root, "replay"))
    HerdrReplayFixture.write_fake_herdr!(fake, replay_dir)
    fake_log = Path.join(root, "fake.log")
    session = "emb1244diff"

    provider_receipt = prepare_provider_receipt!(root, claude)

    real_env = [
      {"XDG_CONFIG_HOME", root},
      {"HERDR_DISABLE_SOUND", "1"},
      {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"},
      {"PATH", provider_receipt.bin <> ":" <> (System.get_env("PATH") || "")}
    ]

    fake_env = real_env ++ [{"HERDR_FAKE_LOG", fake_log}]

    # Version and help text must be byte-identical to the recordings.
    assert version_output == HerdrReplayFixture.stdout!("version")

    for {args, fixture} <- [
          {["agent", "prompt", "--help"], "agent-prompt-help"},
          {["agent", "wait", "--help"], "agent-wait-help"}
        ] do
      {real_output, 0} = System.cmd(real, args, env: real_env)
      assert real_output == HerdrReplayFixture.stdout!(fixture)
    end

    # Real isolated server lifecycle for envelope-shape parity.
    server_task =
      Task.async(fn -> System.cmd(real, ["--session", session, "server"], env: real_env, stderr_to_stdout: true) end)

    on_exit(fn ->
      _ = System.cmd(real, ["--session", session, "server", "stop"], env: real_env, stderr_to_stdout: true)
    end)

    await_real_server!(real, session, real_env)

    fake_session_env = fake_env ++ [{"XDG_CONFIG_HOME", root <> "/fake-state"}]
    File.mkdir_p!(root <> "/fake-state/herdr/sessions/#{session}")
    File.touch!(root <> "/fake-state/herdr/sessions/#{session}/running")

    # status server: same field names in the same order.
    {real_status, 0} = System.cmd(real, ["--session", session, "status", "server"], env: real_env)
    {fake_status, 0} = System.cmd(fake, ["--session", session, "status", "server"], env: fake_session_env)
    assert field_names(real_status) == field_names(fake_status)
    assert real_status =~ "version: 0.8.2"
    assert fake_status =~ "version: 0.8.2"

    # workspace create: identical envelope key shape.
    {real_ws, 0} =
      System.cmd(real, ["--session", session, "workspace", "create", "--cwd", Path.join(root, "ws"), "--no-focus"], env: real_env)

    {fake_ws, 0} =
      System.cmd(fake, ["--session", session, "workspace", "create", "--cwd", Path.join(root, "ws"), "--no-focus"], env: fake_session_env)

    assert json_shape(real_ws) == json_shape(fake_ws)

    # not-found errors: the exact recorded scenario is selected per operation.
    for {command, override} <- [
          {["agent", "get", "missing_agent"], {"HERDR_REPLAY_GET", "error-agent-get-not-found"}},
          {["agent", "wait", "missing_agent", "--timeout", "1000"], {"HERDR_REPLAY_WAIT", "error-agent-wait-not-found"}}
        ] do
      {real_error, 1} = System.cmd(real, ["--session", session] ++ command, env: real_env, stderr_to_stdout: true)

      {fake_error, 1} =
        System.cmd(fake, ["--session", session] ++ command,
          env: fake_session_env ++ [override],
          stderr_to_stdout: true
        )

      assert json_shape(real_error) == json_shape(fake_error)

      assert error_code(real_error) == error_code(fake_error),
             "real and double disagree on error code for #{Enum.join(command, " ")}"
    end

    pane = real_ws |> String.trim() |> Jason.decode!() |> get_in(["result", "root_pane", "pane_id"])

    paused_processes =
      differential_launch_physics!(real, fake, session, root, real_env, fake_session_env, pane, provider_receipt)

    terminate_owned_processes!(paused_processes)

    {_stop_output, 0} =
      System.cmd(real, ["--session", session, "server", "stop"], env: real_env, stderr_to_stdout: true)

    _ = Task.yield(server_task, 5_000) || Task.shutdown(server_task, :brutal_kill)
    assert_owned_processes_dead!(paused_processes)
  end

  # Launch/timing physics that stay executable in the double: provider
  # execution/process replacement on `agent start`, and the 5000 ms
  # prompt-effect boundary (stall vs short-timeout), run against both sides.
  defp differential_launch_physics!(real, fake, session, root, real_env, fake_session_env, pane, provider_receipt) do
    stall_config = Path.join(root, "claude-fresh-config")
    File.mkdir_p!(stall_config)

    {auth_output, _status} =
      System.cmd(provider_receipt.claude, ["auth", "status"],
        env: real_env ++ [{"CLAUDE_CONFIG_DIR", stall_config}],
        stderr_to_stdout: true
      )

    anonymous? = match?({:ok, %{"loggedIn" => false}}, Jason.decode(auth_output))
    assert anonymous?, "differential requires a parseable loggedIn=false result from the fresh provider config"

    Process.sleep(2_000)

    {_run_output, 0} =
      System.cmd(real, ["--session", session, "pane", "run", pane, "export CLAUDE_CONFIG_DIR=#{stall_config}"],
        env: real_env,
        stderr_to_stdout: true
      )

    Process.sleep(1_000)

    # Real provider execution/process replacement: the pane shell is replaced
    # by a live claude TUI that herdr validates as interactively ready.
    # Herdr supplies the executable from --kind; only native arguments follow --.
    {real_start, 0} =
      System.cmd(
        real,
        ["--session", session, "agent", "start", "diff_agent", "--kind", "claude", "--pane", pane] ++
          ["--timeout", "120000", "--", "--model", "haiku"],
        env: real_env
      )

    provider_capture = Path.join(root, "provider-argv.out")
    stub_bin = Path.join(root, "stub-bin")
    File.mkdir_p!(stub_bin)
    stub_claude = Path.join(stub_bin, "claude")
    File.write!(stub_claude, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    File.chmod!(stub_claude, 0o755)

    {fake_start, 0} =
      System.cmd(
        fake,
        ["--session", session, "agent", "start", "diff_agent", "--kind", "claude", "--pane", pane] ++
          ["--timeout", "120000", "--", "--model", "haiku"],
        env:
          fake_session_env ++
            [
              {"HERDR_REPLAY_AGENT_START", "differential-claude-start"},
              {"HERDR_FAKE_LOGIN_PATH", stub_bin <> ":" <> (System.get_env("PATH") || "")},
              {"HERDR_FAKE_PROVIDER_OUTPUT", provider_capture}
            ],
        stderr_to_stdout: true
      )

    assert json_shape(real_start) == json_shape(fake_start)
    assert real_start =~ ~s("interactive_ready":true)

    assert File.read!(provider_capture) == "--dangerously-skip-permissions\n--model\nhaiku\n",
           "the double must prepend the pinned Herdr flag and hand the provider its native argv byte-exact"

    {screen, 0} = System.cmd(real, ["--session", session, "pane", "read", pane, "--source", "visible"], env: real_env)
    onboarding? = String.contains?(screen, "Choose the text style")
    assert onboarding?, "differential must remain on fresh theme onboarding before fault injection"

    paused_processes = owned_provider_processes!(provider_receipt)

    # Register cleanup before any pause. Never resume queued input: kill only
    # receipt-owned, identity-matching processes before native PTY shutdown.
    on_exit(fn ->
      terminate_owned_processes!(paused_processes)
      _ = System.cmd(real, ["--session", session, "server", "stop"], env: real_env, stderr_to_stdout: true)
      assert_owned_processes_dead!(paused_processes)
    end)

    for process <- [paused_processes.shell, paused_processes.provider] do
      assert process_identity(process.pid) == process
      assert {_, 0} = System.cmd("kill", ["-STOP", Integer.to_string(process.pid)])
    end

    Process.sleep(100)
    assert foreground_process_group!(paused_processes.provider.pid) == paused_processes.provider.pgid
    {paused_agent, 0} = System.cmd(real, ["--session", session, "agent", "get", "diff_agent"], env: real_env)

    assert %{"agent" => "claude", "name" => "diff_agent", "agent_status" => "idle", "interactive_ready" => true} =
             paused_agent |> Jason.decode!() |> get_in(["result", "agent"])

    # Explicit test-only timing fault: freeze the pane shell before actual
    # Claude so job control cannot reclaim the foreground. Real Herdr still
    # owns prompt input and the 5000 ms stall boundary. The provider is never
    # resumed and cannot consume these queued bytes or advance into login.
    prompt_args = fn timeout ->
      ["--session", session, "agent", "prompt", "diff_agent", "x", "--wait"] ++
        ["--until", "working", "--until", "idle", "--until", "done", "--until", "blocked"] ++
        ["--timeout", timeout]
    end

    {real_stalled, 1} = System.cmd(real, prompt_args.("6500"), env: real_env, stderr_to_stdout: true)
    {real_short, 1} = System.cmd(real, prompt_args.("4000"), env: real_env, stderr_to_stdout: true)

    stall_env = fake_session_env ++ [{"HERDR_FAKE_PROMPT_STALL_COUNT", "9"}]
    {fake_stalled, 1} = System.cmd(fake, prompt_args.("6500"), env: stall_env, stderr_to_stdout: true)
    {fake_short, 1} = System.cmd(fake, prompt_args.("4000"), env: stall_env, stderr_to_stdout: true)

    assert error_code(real_stalled) == "agent_prompt_stalled"
    assert error_code(real_stalled) == error_code(fake_stalled)
    assert error_code(real_short) == "timeout"
    assert error_code(real_short) == error_code(fake_short)

    differential_pane_busy!(real, fake, session, root, real_env, fake_session_env)
    paused_processes
  end

  defp prepare_provider_receipt!(root, claude) do
    bin = Path.join(root, "real-provider-bin")
    path = Path.join(root, "provider-process.receipt")
    token = Base.encode16(:crypto.strong_rand_bytes(16))
    File.mkdir_p!(bin)
    File.chmod!(bin, 0o700)

    File.write!(Path.join(bin, "claude"), """
    #!/bin/sh
    umask 077
    printf '%s\\n' '#{token}' "$$" "$PPID" > #{shell_quote(path)}
    exec #{shell_quote(claude)} "$@"
    """)

    File.chmod!(Path.join(bin, "claude"), 0o700)
    %{bin: bin, path: path, token: token, claude: claude}
  end

  defp owned_provider_processes!(receipt) do
    assert [token, provider_pid, shell_pid] = receipt.path |> File.read!() |> String.split()
    assert token == receipt.token
    provider = process_identity(String.to_integer(provider_pid))
    shell = process_identity(String.to_integer(shell_pid))
    assert is_map(provider) and is_map(shell), "receipt-owned provider and pane shell must exist"
    assert provider.pid > 1 and shell.pid > 1 and provider.pid != shell.pid
    assert provider.ppid == shell.pid
    assert Path.basename(provider.command) == "claude", "receipt must identify actual Claude after exec"
    assert Path.basename(shell.command) in ~w(sh dash bash zsh ksh fish), "receipt parent must be the pane shell"
    assert foreground_process_group!(provider.pid) == provider.pgid
    %{provider: provider, shell: shell}
  end

  # ps lstart/comm/tpgid support is checked explicitly at this opt-in boundary.
  # Process identity policy remains test-local; no production PID API changes.
  defp process_identity(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "pid=,ppid=,pgid=,lstart=,comm="],
           env: [{"LC_ALL", "C"}],
           stderr_to_stdout: true
         ) do
      {"", 1} ->
        nil

      {output, 0} ->
        assert [pid, ppid, pgid, day, month, date, clock, year, command] = String.split(String.trim(output), ~r/\s+/, parts: 9)

        %{
          pid: String.to_integer(pid),
          ppid: String.to_integer(ppid),
          pgid: String.to_integer(pgid),
          started_at: Enum.join([day, month, date, clock, year], " "),
          command: command
        }

      _ ->
        flunk("differential requires ps with pid, ppid, pgid, lstart and comm fields")
    end
  end

  defp foreground_process_group!(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "tpgid="], stderr_to_stdout: true) do
      {output, 0} -> String.to_integer(String.trim(output))
      _ -> flunk("differential requires ps with the tpgid field")
    end
  end

  defp terminate_owned_processes!(processes) do
    for expected <- [processes.provider, processes.shell] do
      case process_identity(expected.pid) do
        nil ->
          :ok

        ^expected ->
          assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(expected.pid)])

        _ ->
          flunk("receipt-owned process identity changed; refusing to signal a different process")
      end
    end
  end

  defp assert_owned_processes_dead!(processes) do
    Enum.reduce_while(1..100, :waiting, fn _, _ ->
      if Enum.all?([processes.provider, processes.shell], &(process_identity(&1.pid) == nil)) do
        {:halt, :dead}
      else
        Process.sleep(20)
        {:cont, :waiting}
      end
    end)
    |> then(&assert(&1 == :dead, "receipt-owned paused processes survived cleanup"))
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  # Pane-busy launch physics: the same occupied-pane scenario that recorded
  # the error-agent-start-pane-busy fixture, run against the real binary and
  # replayed by the double, must yield the same typed error.
  defp differential_pane_busy!(real, fake, session, root, real_env, fake_session_env) do
    {busy_ws, 0} =
      System.cmd(real, ["--session", session, "workspace", "create", "--cwd", Path.join(root, "ws")], env: real_env)

    busy_pane = busy_ws |> String.trim() |> Jason.decode!() |> get_in(["result", "root_pane", "pane_id"])
    Process.sleep(2_000)

    {_busy_run, 0} =
      System.cmd(real, ["--session", session, "pane", "run", busy_pane, "sleep 120"],
        env: real_env,
        stderr_to_stdout: true
      )

    Process.sleep(1_000)

    start_args = fn pane ->
      ["--session", session, "agent", "start", "busy_agent", "--kind", "claude", "--pane", pane] ++
        ["--timeout", "8000", "--", "--model", "haiku"]
    end

    {real_busy, 1} = System.cmd(real, start_args.(busy_pane), env: real_env, stderr_to_stdout: true)

    {fake_busy, 1} =
      System.cmd(fake, start_args.(busy_pane),
        env: fake_session_env ++ [{"HERDR_FAKE_PANE_BUSY_COUNT", "1"}],
        stderr_to_stdout: true
      )

    assert error_code(real_busy) == "agent_pane_busy"
    assert error_code(real_busy) == error_code(fake_busy)
    assert json_shape(real_busy) == json_shape(fake_busy)
  end

  defp await_real_server!(real, session, env) do
    Enum.reduce_while(1..100, :ok, fn _attempt, :ok ->
      if real_server_running?(real, session, env) do
        {:halt, :ok}
      else
        Process.sleep(100)
        {:cont, :ok}
      end
    end)
  end

  defp real_server_running?(real, session, env) do
    case System.cmd(real, ["--session", session, "status", "server"], env: env, stderr_to_stdout: true) do
      {output, 0} -> output =~ "status: running"
      _failure -> false
    end
  end

  defp field_names(status_text) do
    status_text
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> line |> String.split(":", parts: 2) |> hd() end)
  end

  defp json_shape(output) do
    output
    |> String.trim()
    |> Jason.decode!()
    |> shape()
  end

  defp shape(map) when is_map(map), do: map |> Map.new(fn {key, value} -> {key, shape(value)} end)
  defp shape(list) when is_list(list), do: Enum.map(list, &shape/1)
  defp shape(value) when is_binary(value), do: :string
  defp shape(value) when is_integer(value), do: :integer
  defp shape(value) when is_float(value), do: :float
  defp shape(value) when is_boolean(value), do: :boolean
  defp shape(nil), do: nil

  defp error_code(output) do
    output |> String.trim() |> Jason.decode!() |> get_in(["error", "code"])
  end
end
