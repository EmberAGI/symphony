defmodule SymphonyElixir.TestSupport.NonLiveLinearClient do
  @moduledoc """
  Suite-default deterministic Linear client: the non-live gate must perform
  zero Linear network I/O, so the Adapter seam resolves to this module unless
  a test explicitly installs its own fake. Fetches succeed with an empty
  issue set so incidental orchestrator activity (startup cleanup, polls)
  proceeds quietly; GraphQL mutations fail locally and visibly so a test
  that genuinely exercises Linear mutation contracts must opt into its own
  fake client instead of silently relying on this default.
  """

  def fetch_candidate_issues, do: {:ok, []}

  def fetch_issues_by_states(_state_names), do: {:ok, []}

  def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

  def graphql(query, variables \\ %{}, opts \\ [])

  def graphql(_query, _variables, _opts), do: {:error, :non_live_gate_linear_client}
end
