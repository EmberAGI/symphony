defmodule SymphonyElixir.AgentRuntimeStaleWorkingConfigTest do
  # TUR-1006 AC4: the Implementer delegation stale-working bound is a
  # validated, documented production configuration value
  # (`agent_runtime.stale_working_ms`, default 900000) rather than a constant
  # duplicated across the supervision Module and the delegation entry point.
  # It is a documented field only: the default is unchanged and raising it is
  # never a substitute for real-work progress detection.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Workflow

  describe "agent_runtime.stale_working_ms" do
    test "defaults to the existing 900000 ms supervision bound" do
      write_stale_working_workflow_file!("default", nil)

      assert %{agent_runtime: %{stale_working_ms: stale_working_ms}} = Config.settings!(),
             "stale_working_ms must be reachable from Config.settings!/0"

      assert stale_working_ms == 900_000, "the shipped default must stay 900000"
    end

    test "a configured value is validated and surfaced through settings" do
      write_stale_working_workflow_file!("configured", 1_200_000)

      assert %{agent_runtime: %{stale_working_ms: 1_200_000}} = Config.settings!()
    end

    test "a non-positive value is rejected as an invalid workflow config naming the field" do
      write_stale_working_workflow_file!("invalid", 0)

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "agent_runtime.stale_working_ms"
    end
  end

  defp write_stale_working_workflow_file!(label, stale_working_ms) do
    test_root = unique_test_root("stale-working-config-#{label}")
    File.mkdir_p!(Path.join(test_root, "workspaces"))
    staging_path = Path.join(test_root, "staging-workflow.yaml")
    workflow_path = Path.join(test_root, "workflow.yaml")

    previous_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(previous_path)
      File.rm_rf(test_root)
    end)

    write_workflow_file!(staging_path,
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      agent_runtime_provider: "claude_code"
    )

    body = File.read!(staging_path)

    body =
      if is_integer(stale_working_ms) do
        String.replace(
          body,
          ~r/^agent_runtime:$/m,
          "agent_runtime:\n  stale_working_ms: #{stale_working_ms}",
          global: false
        )
      else
        body
      end

    File.write!(workflow_path, body)
    Workflow.set_workflow_file_path(workflow_path)

    :ok
  end

  defp unique_test_root(label) do
    Path.join(System.tmp_dir!(), "symphony-elixir-#{label}-#{System.unique_integer([:positive])}")
  end
end
