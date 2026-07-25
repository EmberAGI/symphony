defmodule SymphonyElixir.ImplementerOrchestratorProtocolDeliveryTest do
  use ExUnit.Case, async: false

  @moduledoc """
  RED: the orchestrator profile reaches the launched provider entire, or not at all.

  `AgentProfileCatalog` carries the whole markdown body of an `*.agent.md`
  profile as `instructions`, `ImplementationEffort` threads it onto
  `contract.orchestrator`, and `ImplementerDelegation.launcher_argv/4` renders
  it into the Codex launch argv as
  `--config developer_instructions=\#{inspect(instructions)}`.

  `inspect/1` truncates a printable binary at its `:printable_limit`, which
  defaults to 4096 bytes, and appends the Elixir truncation marker `<> ...`.
  Every real agent profile is larger than that, so everything past byte 4096 —
  including the worker-assignment protocol the delegation evidence contract
  depends on — is silently dropped before the orchestrator is ever launched.
  The suite never caught it because the shared profile fixture body is one
  short line.

  These tests pin the whole profile arriving at the provider launch.
  """

  alias SymphonyElixir.{AgentRuntime, ImplementationEffort}
  alias SymphonyElixir.ImplementerDelegation.HerdrTransport
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TestSupport.HerdrReplayFixture

  @assignment_protocol "OCTO_MSG/1 kind=assignment assignment=<ID> deliverable=<SLUG>"
  @result_protocol "OCTO_MSG/1 kind=result assignment=<ID> status=completed"

  setup do
    root = Path.join(System.tmp_dir!(), "iopd-#{System.unique_integer([:positive])}")
    provider_bin = Path.join(root, "provider-bin")
    workspace = Path.join(root, "selected-product")
    profiles = Path.join(root, "agent-profiles")

    File.mkdir_p!(provider_bin)
    File.mkdir_p!(workspace)
    File.mkdir_p!(profiles)

    for provider <- ["codex", "claude"] do
      fake = Path.join(provider_bin, provider)
      File.write!(fake, "#!/bin/sh\nexit 0\n")
      File.chmod!(fake, 0o755)
    end

    write_profile!(profiles, "implementer-orchestrator", "orchestrator", true, @assignment_protocol)
    write_profile!(profiles, "implementer-worker", "worker", false, @result_protocol)

    previous_path = System.get_env("PATH") || ""
    previous_profiles = System.get_env("SYMPHONY_AGENT_PROFILES")
    previous_provider = System.get_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
    previous_transport = Application.get_env(:symphony_elixir, :delegation_transport_module)

    System.put_env("PATH", provider_bin <> ":" <> previous_path)
    System.put_env("SYMPHONY_AGENT_PROFILES", profiles)
    System.put_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", "codex")
    Application.put_env(:symphony_elixir, :delegation_transport_module, HerdrTransport)

    herdr_bin = Path.join(root, "fake-herdr")
    replay_dir = Path.join(root, "herdr-replay")
    HerdrReplayFixture.materialize_replay_dir!(replay_dir)
    HerdrReplayFixture.write_fake_herdr!(herdr_bin, replay_dir)

    runtime_root = Path.join(System.tmp_dir!(), "iopd-rt-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      restore_env("SYMPHONY_AGENT_PROFILES", previous_profiles)
      restore_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER", previous_provider)
      Application.put_env(:symphony_elixir, :delegation_transport_module, previous_transport)
      File.rm_rf(root)
      File.rm_rf(runtime_root)
    end)

    {:ok, workspace: workspace, herdr_bin: herdr_bin, herdr_log: Path.join(root, "herdr.log"), runtime_root: runtime_root}
  end

  test "the resolved contract carries the whole profile, protocol section included" do
    assert {:ok, contract} = ImplementationEffort.runtime_profile_for_issue(:codex, issue(), "implementer")

    assert byte_size(contract.orchestrator.instructions) > 4096
    assert contract.orchestrator.instructions =~ @assignment_protocol
    assert contract.worker.instructions =~ @result_protocol
  end

  test "the launched orchestrator receives the assignment protocol, not a 4096-byte prefix", context do
    assert {:ok, session} = start_implementer_session(context)

    projections =
      context.runtime_root
      |> Path.join("launch-projections/*.sh")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    assert projections != ""

    # Elixir's binary truncation marker. Its presence means the provider was
    # launched with a profile prefix plus a literal `<> ...`, which is not even
    # a well-formed TOML value for `--config developer_instructions=`.
    refute projections =~ "<> ..."

    assert projections =~ @assignment_protocol
    assert projections =~ @result_protocol

    assert :ok = AgentRuntime.stop_session(session)
  end

  defp start_implementer_session(context) do
    AgentRuntime.start_session(context.workspace,
      issue: issue(),
      role: "implementer",
      run_id: "protocol-delivery",
      delegation_transport_context: %{
        herdr_bin: context.herdr_bin,
        extra_env: [{"HERDR_FAKE_LOG", context.herdr_log}],
        socket_root: context.runtime_root,
        poll_interval_ms: 5,
        start_timeout_ms: 2_000
      }
    )
  end

  # A profile the size of a real one: the protocol section sits well past the
  # 4096-byte boundary, exactly where production profiles put it.
  defp write_profile!(root, name, kind, can_delegate, protocol) do
    owns_run = kind == "orchestrator"

    filler =
      Enum.map_join(1..90, "\n", fn index ->
        "- Operating rule #{index}: keep every bounded deliverable small, reviewable and evidence-bearing."
      end)

    File.write!(Path.join(root, "#{name}.agent.md"), """
    +++
    schema_version = 1
    name = "#{name}"
    kind = "#{kind}"
    role = "implementer"

    [capabilities]
    can_delegate = #{can_delegate}
    max_delegation_depth = #{if(can_delegate, do: 1, else: 0)}
    owns_issue_lifecycle = #{owns_run}
    owns_final_validation = #{owns_run}
    owns_handoff = #{owns_run}

    [providers.codex]
    default_tier = "moderate"
    #{provider_rows("gpt-5.6-sol", ~w(xhigh high medium low none))}

    [providers.claude_code]
    default_tier = "moderate"
    #{provider_rows("claude-fable-5", ~w(xhigh high medium low low))}
    +++

    # #{name}

    #{filler}

    ## Worker assignment protocol

    Delegate bounded work with the literal envelope:

        #{protocol}
    """)
  end

  defp provider_rows(model, efforts) do
    ~w(extreme high moderate low minimal)
    |> Enum.zip(efforts)
    |> Enum.map_join("\n", fn {tier, effort} ->
      ~s(#{tier} = { model = "#{model}", reasoning_effort = "#{effort}" })
    end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp issue do
    %Issue{
      id: "issue-protocol-delivery",
      identifier: "EMB-PROTOCOL",
      title: "Deliver the whole orchestrator profile",
      state: "In Progress",
      branch_name: "octo/emb-protocol-deliver-profile",
      url: "https://linear.app/emberai/issue/EMB-PROTOCOL",
      repository: "EmberAGI/scaling-octo-engine",
      repository_source: "linear_label",
      labels: ["implementation-effort:moderate"]
    }
  end
end
