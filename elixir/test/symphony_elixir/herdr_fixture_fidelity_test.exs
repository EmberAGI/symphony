defmodule SymphonyElixir.HerdrFixtureFidelityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestSupport.HerdrReplayFixture

  @moduledoc """
  Fidelity gate for the recorded Herdr protocol fixtures (EMB-1244).

  Fails the suite when any committed fixture claims an out-of-enum agent
  status, loses its raw provenance, stops being a pure recording, or drifts
  from their declared binaries. Committed fixtures are CI inputs; recording
  itself is the CD-tier concern documented in the fixtures README.
  """

  @required_provenance_keys ~w(argv stdout stderr exit_status recorded_at herdr_version herdr_binary_sha256 provenance derivation redaction name)
  @declared_placeholders ~w({{AGENT_NAME}} {{AGENT_KIND}} {{SOCKET_PATH}} {{WORKSPACE_CWD}} {{PANE_ID}})
  @known_error_codes ~w(agent_blocked agent_not_found agent_not_ready agent_pane_busy agent_prompt_stalled timeout)
  @v082_binary_sha256 "976150a14d490c94b243ea2e1a7eb2dfb67f12e36b182db90936f6728e6aecf4"
  @v075_binary_sha256 "37350546b0012555943b92eaf962665de4e264395baeb44227b8015e8ff5b0d6"

  test "every fixture is a pure recording with complete raw provenance" do
    names = HerdrReplayFixture.fixture_names()
    assert names != []

    for name <- names do
      fixture = HerdrReplayFixture.load!(name)

      for key <- @required_provenance_keys do
        assert Map.has_key?(fixture, key), "#{name} is missing provenance key #{key}"
      end

      assert fixture["provenance"] == "recorded",
             "#{name} is not a pure recording; synthesized or derived protocol fixtures are forbidden"

      assert fixture["derivation"] == nil
      assert fixture["herdr_version"] == "herdr 0.8.2"
      assert fixture["herdr_binary_sha256"] == @v082_binary_sha256
      assert fixture["redaction"] != ""
      assert is_list(fixture["argv"]) and fixture["argv"] != []
      assert is_integer(fixture["exit_status"])
      assert {:ok, _timestamp, _offset} = DateTime.from_iso8601(fixture["recorded_at"])
    end

    shas =
      names
      |> Enum.map(&HerdrReplayFixture.load!(&1)["herdr_binary_sha256"])
      |> Enum.uniq()
      |> Enum.sort()

    assert shas == [@v082_binary_sha256],
           "current fixtures did not come from the exact audited Herdr v0.8.2 binary"
  end

  test "historical v0.7.5 recordings remain isolated parser-regression inputs" do
    names = HerdrReplayFixture.legacy_fixture_names()
    assert names != []

    for name <- names do
      fixture = HerdrReplayFixture.load_legacy!(name)
      assert fixture["herdr_version"] == "herdr 0.7.5"
      assert fixture["herdr_binary_sha256"] == @v075_binary_sha256
    end
  end

  test "every agent status claimed by any fixture is inside the five-state enum" do
    for name <- HerdrReplayFixture.fixture_names() do
      fixture = HerdrReplayFixture.load!(name)

      statuses =
        Regex.scan(~r/"agent_status":"([^"]+)"/, fixture["stdout"] <> fixture["stderr"], capture: :all_but_first)
        |> List.flatten()

      for status <- statuses do
        assert status in HerdrReplayFixture.known_statuses(),
               "#{name} claims out-of-enum agent status #{inspect(status)}"
      end
    end
  end

  test "every error code claimed by any fixture is a recorded real-binary code" do
    for name <- HerdrReplayFixture.fixture_names() do
      fixture = HerdrReplayFixture.load!(name)

      codes =
        Regex.scan(~r/"code":"([^"]+)"/, fixture["stdout"] <> fixture["stderr"], capture: :all_but_first)
        |> List.flatten()

      for code <- codes do
        assert code in @known_error_codes, "#{name} claims unrecorded error code #{inspect(code)}"
      end
    end
  end

  test "the agent-start envelope parameterizes its run-varying target pane" do
    assert HerdrReplayFixture.stdout!("agent-start") =~ ~s("pane_id":"{{PANE_ID}}"),
           "agent-start must not pin the recording's pane: workers start on other panes"

    assert HerdrReplayFixture.load!("agent-start")["redaction"] =~ "declared placeholders"
  end

  test "v0.8.2 evidence deletes the obsolete separate Enter recording" do
    refute "agent-send-keys-enter" in HerdrReplayFixture.fixture_names()
    assert HerdrReplayFixture.load!("error-agent-prompt-blocked")["herdr_version"] == "herdr 0.8.2"
    assert HerdrReplayFixture.load!("error-agent-start-not-ready")["herdr_version"] == "herdr 0.8.2"
  end

  test "the real v0.8.2 prompt path owns bracketed paste and exactly one delayed Enter" do
    fixture = HerdrReplayFixture.load!("prompt-delivery-bytes")

    assert fixture["captured_input_hex"] ==
             "1b5b3230307e50494e471b5b3230317e0a" <>
               "1b5b3230307e414741494e1b5b3230317e0a"

    assert fixture["input_provenance"] =~ "foreground provider process"
    refute fixture["captured_input_hex"] =~ "0a0a"
  end

  test "exact Codex and Claude recordings preserve prompted-agent provider identity" do
    for provider <- ["codex", "claude"] do
      start = recorded_agent!("provider-identity-#{provider}-start")
      prompted = recorded_agent!("provider-identity-#{provider}-prompt")
      completed = recorded_agent!("provider-identity-#{provider}-wait")

      assert start["agent"] == provider
      assert start["name"] == "{{AGENT_NAME}}"

      observations = if provider == "codex", do: [start, prompted, completed], else: [prompted, completed]

      for observed <- observations do
        assert observed["agent"] == provider
        assert observed["name"] == "{{AGENT_NAME}}"
        assert observed["agent_session"]["agent"] == provider
        assert observed["agent_session"]["source"] == "herdr:#{provider}"
        assert observed["agent_session"]["value"] == "#{provider}-session-tur844"
      end
    end
  end

  test "provider identity recordings cross their claimed native operation" do
    for provider <- ["codex", "claude"],
        {phase, command, envelope_id} <- [
          {"start", "start", "cli:agent:start"},
          {"prompt", "prompt", "cli:agent:prompt"},
          {"wait", "wait", "cli:agent:wait"}
        ] do
      fixture = HerdrReplayFixture.load!("provider-identity-#{provider}-#{phase}")
      envelope = Jason.decode!(fixture["stdout"])
      agent_command_index = Enum.find_index(fixture["argv"], &(&1 == "agent"))

      assert is_integer(agent_command_index), "#{provider} #{phase} recording has no agent command"
      assert Enum.at(fixture["argv"], agent_command_index + 1) == command
      assert envelope["id"] == envelope_id
    end
  end

  test "every structured response envelope matches its recorded operation argv" do
    for name <- HerdrReplayFixture.fixture_names() do
      fixture = HerdrReplayFixture.load!(name)

      with {:ok, envelope} <- recorded_envelope(fixture),
           "cli:" <> _operation <- envelope["id"] do
        assert envelope["id"] == expected_envelope_id!(fixture["argv"]),
               "#{name} relabels #{inspect(fixture["argv"])} as #{inspect(envelope["id"])}"
      end
    end
  end

  test "an already-blocked prompt records unchanged foreground-provider input" do
    fixture = HerdrReplayFixture.load!("error-agent-prompt-blocked")

    assert fixture["captured_input_bytes_before"] == 5
    assert fixture["captured_input_bytes_after"] == fixture["captured_input_bytes_before"]
    assert fixture["captured_input_sha256_after"] == fixture["captured_input_sha256_before"]
    assert fixture["input_provenance"] =~ "foreground Codex process"
    assert fixture["input_provenance"] =~ "delayed-Enter observation window"
  end

  test "release authority pins the exact v0.8.2 generation" do
    authority =
      Path.expand("../fixtures/herdr/0.8.2/release-authority.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert authority["release_commit"] == "9eb521456ac0d19d3ab3d9d7cea3cca10baa8a4c"
    assert authority["tag"] == "v0.8.2"
    assert authority["tag_type"] == "annotated"
    assert authority["tag_peels_to"] == authority["release_commit"]
    assert authority["protocol"] == 20
    assert authority["version"] == "0.8.2"

    assert authority["source_assertions"] == %{
             "Cargo.toml.package.version" => "0.8.2",
             "src/protocol/wire.rs.PROTOCOL_VERSION" => 20
           }

    assert authority["source_hashes"] == %{
             "LICENSE" => "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
             "skills/herdr/SKILL.md" => "237ad2ab2d8123e2bb37956d3a41eed141f2d22a7c36e415b7876c0397679099"
           }

    assert authority["release_assets"] == %{
             "herdr-linux-aarch64" => "f55610658e1c2e0d2aaef730b4b2ab885f7f8ba00285ab372bfb14f2e3d5b40d",
             "herdr-linux-x86_64" => @v082_binary_sha256,
             "herdr-macos-aarch64" => "a5d4f4d504d8b309c91f811050559300faba31258425f53c50852fc96f6ae574",
             "herdr-macos-x86_64" => "ab50262c8190cd7aa9056d249d255c08c328c3e8716de9cfa29db4f131b8e2c1"
           }
  end

  test "fixtures use only the declared run-varying placeholders" do
    for name <- HerdrReplayFixture.fixture_names() do
      fixture = HerdrReplayFixture.load!(name)

      placeholders =
        Regex.scan(~r/\{\{[A-Z_]+\}\}/, fixture["stdout"] <> fixture["stderr"])
        |> List.flatten()
        |> Enum.uniq()

      for placeholder <- placeholders do
        assert placeholder in @declared_placeholders,
               "#{name} uses undeclared placeholder #{placeholder}"
      end
    end
  end

  test "the recorded help output documents exactly the pinned five-state enum and default settle set" do
    assert HerdrReplayFixture.documented_statuses!() == HerdrReplayFixture.known_statuses()

    wait_help = HerdrReplayFixture.stdout!("agent-wait-help")
    assert wait_help =~ "Without --until, matches idle, done, or blocked."

    prompt_help = HerdrReplayFixture.stdout!("agent-prompt-help")
    assert prompt_help =~ "within 5000ms; otherwise it returns agent_prompt_stalled"
    assert prompt_help =~ "It then matches idle, done, or blocked by default"
  end

  test "each enum status observable from the real binary is witnessed by at least one recording" do
    all_stdout =
      HerdrReplayFixture.fixture_names()
      |> Enum.map_join("\n", &HerdrReplayFixture.stdout!/1)

    for status <- ["idle", "working", "blocked", "done"] do
      assert all_stdout =~ ~s("agent_status":"#{status}"),
             "no recording witnesses agent status #{status}"
    end

    # `unknown` was never observable as a live-agent envelope status; it is
    # witnessed by the recorded pane-split envelope (an agentless shell pane)
    # and by the recorded help enum, and its typed handling is exercised via
    # the transport seam.
    assert HerdrReplayFixture.stdout!("pane-split") =~ ~s("agent_status":"unknown")
  end

  defp recorded_agent!(name) do
    name
    |> HerdrReplayFixture.stdout!()
    |> Jason.decode!()
    |> get_in(["result", "agent"])
  end

  defp recorded_envelope(fixture) do
    [fixture["stdout"], fixture["stderr"]]
    |> Enum.find(&String.starts_with?(&1, "{"))
    |> case do
      nil -> :not_structured
      json -> Jason.decode(json)
    end
  end

  defp expected_envelope_id!(argv) do
    for group <- ~w(agent pane workspace),
        group_index = Enum.find_index(argv, &(&1 == group)),
        is_integer(group_index),
        operation = Enum.at(argv, group_index + 1),
        is_binary(operation),
        reduce: nil do
      nil -> "cli:#{group}:#{operation}"
      _duplicate -> flunk("recorded argv contains multiple protocol operation groups: #{inspect(argv)}")
    end || flunk("structured recording has no protocol operation argv: #{inspect(argv)}")
  end
end
