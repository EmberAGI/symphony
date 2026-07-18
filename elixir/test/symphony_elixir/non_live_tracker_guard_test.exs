defmodule SymphonyElixir.NonLiveTrackerGuardTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  Non-live gate guard at the shared workflow-config write seam: the default
  `make all` suite must perform zero real Linear I/O. Any test configuration
  that could reach api.linear.app (or any other non-loopback host) through
  the Linear tracker with a usable token fails at `write_workflow_file!/2`
  itself, so an attempting test fails loudly instead of silently issuing
  network requests. The dummy token shape stays available for secret
  redaction proofs, and the schema's production endpoint default stays
  intact for token-less parse assertions.
  """

  test "suite default runs the memory tracker fixture with the dummy token shape" do
    write_workflow_file!(Workflow.workflow_file_path())

    config = Config.settings!()
    assert config.tracker.kind == "memory"
    assert config.tracker.api_key == "token"
    assert URI.parse(config.tracker.endpoint).host in ["127.0.0.1", "localhost", "::1"]
  end

  test "linear adapter resolves to the deterministic non-live client by default" do
    assert Application.get_env(:symphony_elixir, :linear_client_module) ==
             SymphonyElixir.TestSupport.NonLiveLinearClient

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    # Fetches drain quietly with no socket; mutations fail locally so a test
    # exercising Linear mutation contracts must install its own fake client.
    assert {:ok, []} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:error, _reason} = SymphonyElixir.Tracker.create_comment("issue-1", "body")
  end

  test "linear opt-ins are allowed only against loopback endpoints" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    assert Config.settings!().tracker.kind == "linear"
    assert URI.parse(Config.settings!().tracker.endpoint).host in ["127.0.0.1", "localhost", "::1"]
  end

  test "write seam fails a linear tracker pointed at api.linear.app with a token" do
    assert_raise ArgumentError, ~r/non-live gate/, fn ->
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_endpoint: "https://api.linear.app/graphql",
        tracker_api_token: "token"
      )
    end
  end

  test "write seam fails an implicit external endpoint via the schema default with a token" do
    assert_raise ArgumentError, ~r/non-live gate/, fn ->
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_endpoint: nil,
        tracker_api_token: "token"
      )
    end
  end

  test "memory tracker and token-less linear configs stay allowed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_endpoint: nil,
      tracker_api_token: nil
    )

    assert Config.settings!().tracker.endpoint == "https://api.linear.app/graphql"
  end
end
