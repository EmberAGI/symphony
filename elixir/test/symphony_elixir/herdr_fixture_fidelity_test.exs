defmodule SymphonyElixir.HerdrFixtureFidelityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestSupport.HerdrReplayFixture

  @moduledoc """
  Fidelity gate for the recorded herdr 0.7.5 protocol fixtures (EMB-1244).

  Fails the suite when any committed fixture claims an out-of-enum agent
  status, loses its raw provenance, stops being a pure recording, or drifts
  from the pinned 0.7.5 contract. Committed fixtures are CI inputs; recording
  itself is the CD-tier concern documented in the fixtures README.
  """

  @required_provenance_keys ~w(argv stdout stderr exit_status recorded_at herdr_version herdr_binary_sha256 provenance derivation redaction name)
  @declared_placeholders ~w({{AGENT_NAME}} {{AGENT_KIND}} {{SOCKET_PATH}} {{WORKSPACE_CWD}} {{PANE_ID}})
  @known_error_codes ~w(agent_not_found agent_pane_busy agent_prompt_stalled timeout)
  @recorded_binary_sha256s ~w(
    37350546b0012555943b92eaf962665de4e264395baeb44227b8015e8ff5b0d6
    3dc83288073e4c2d3c679a30e7be97bcca9141c6fd17dbbb9219142e95c59253
  )

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
      assert fixture["herdr_version"] == "herdr 0.7.5"
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

    assert shas == Enum.sort(@recorded_binary_sha256s),
           "fixtures did not come from the exact audited Herdr 0.7.5 binaries"
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

    assert HerdrReplayFixture.load!("agent-start")["redaction"] =~ "{{PANE_ID}}"
  end

  test "the agent-scoped Enter acknowledgement is a required real recording" do
    fixture = HerdrReplayFixture.load!("agent-send-keys-enter")

    assert fixture["argv"] |> Enum.take(-4) ==
             ["agent", "send-keys", "emb1312probe", "enter"]

    assert fixture["provenance"] == "recorded"
    assert fixture["derivation"] == nil
    assert fixture["herdr_binary_sha256"] == "3dc83288073e4c2d3c679a30e7be97bcca9141c6fd17dbbb9219142e95c59253"
    assert Jason.decode!(fixture["stdout"]) == %{"id" => "cli:agent:send-keys", "result" => %{"type" => "ok"}}
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
end
