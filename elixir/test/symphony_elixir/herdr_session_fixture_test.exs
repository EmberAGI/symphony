defmodule SymphonyElixir.HerdrSessionFixtureTest do
  use ExUnit.Case, async: false

  @tag timeout: 60_000
  test "an assertion failure tears down only its session before removing fixtures" do
    assert_probe_cleanup("failure")
  end

  @tag timeout: 60_000
  test "normal completion permits repeated cleanup without affecting another process" do
    assert_probe_cleanup("success")
  end

  @tag timeout: 60_000
  test "a failed direct transport test also cleans its session" do
    assert_probe_cleanup("failure", "transport")
  end

  defp assert_probe_cleanup(outcome, kind \\ "runtime") do
    root = Path.join(System.tmp_dir!(), "ht-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    sentinel = Port.open({:spawn_executable, System.find_executable("sleep")}, [:exit_status, args: ["60"]])
    {:os_pid, sentinel_pid} = Port.info(sentinel, :os_pid)

    on_exit(fn ->
      if Port.info(sentinel), do: Port.close(sentinel)
      System.cmd("kill", ["-TERM", Integer.to_string(sentinel_pid)], stderr_to_stdout: true)

      # The outer proof must clean its deliberately broken RED child too.
      case File.read(Path.join(root, "pid")) do
        {:ok, pid} -> System.cmd("kill", ["-TERM", String.trim(pid)], stderr_to_stdout: true)
        _ -> :ok
      end

      File.rm_rf!(root)
    end)

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "--no-compile", "--no-deps-check", "test/support/herdr_session_teardown_probe.exs"],
        env: [{"MIX_ENV", "test"}, {"TEARDOWN_PROBE_ROOT", root}, {"TEARDOWN_PROBE_OUTCOME", outcome}, {"TEARDOWN_PROBE_KIND", kind}],
        stderr_to_stdout: true
      )

    if outcome == "failure" do
      assert status != 0
      assert output =~ "intentional teardown probe failure"
    else
      assert status == 0, output
    end

    pid = root |> Path.join("pid") |> File.read!() |> String.trim()
    runtime = root |> Path.join("runtime-path") |> File.read!()
    assert {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0, "assertion failure left fixture PID #{pid} alive\n" <> output <> File.read!(Path.join(root, "commands"))
    refute File.exists?(runtime), output <> "\n" <> File.read!(Path.join(root, "commands"))
    refute File.exists?(Path.join(root, "fixtures"))
    assert {_, 0} = System.cmd("kill", ["-0", Integer.to_string(sentinel_pid)], stderr_to_stdout: true)
  end
end
