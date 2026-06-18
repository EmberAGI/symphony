defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.ClaimLease

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @create_claim_lease_comment_mutation """
  mutation SymphonyCreateClaimLeaseComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
      }
    }
  }
  """

  @update_claim_lease_comment_mutation """
  mutation SymphonyUpdateClaimLeaseComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec upsert_claim_lease(String.t(), map()) :: {:ok, ClaimLease.t() | nil} | {:error, term()}
  def upsert_claim_lease(issue_id, lease_attrs) when is_binary(issue_id) and is_map(lease_attrs) do
    lease =
      lease_attrs
      |> Map.put(:issue_id, issue_id)
      |> ClaimLease.new()

    with :ok <- write_claim_lease_comment(lease),
         {:ok, [refetched_issue | _]} <- client_module().fetch_issue_states_by_ids([issue_id]),
         %ClaimLease{} = verified <- Map.get(refetched_issue, :claim_lease),
         true <- verified.holder == lease.holder and verified.run_id == lease.run_id do
      {:ok, verified}
    else
      {:ok, []} -> {:error, :claim_lease_issue_not_found}
      false -> {:error, :claim_lease_ownership_verification_failed}
      nil -> {:error, :claim_lease_missing_after_upsert}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :claim_lease_upsert_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp write_claim_lease_comment(%ClaimLease{comment_id: comment_id} = lease)
       when is_binary(comment_id) do
    with {:ok, response} <-
           client_module().graphql(@update_claim_lease_comment_mutation, %{
             commentId: comment_id,
             body: claim_lease_comment_body(lease)
           }),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :claim_lease_comment_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :claim_lease_comment_update_failed}
    end
  end

  defp write_claim_lease_comment(%ClaimLease{} = lease) do
    with {:ok, response} <-
           client_module().graphql(@create_claim_lease_comment_mutation, %{
             issueId: lease.issue_id,
             body: claim_lease_comment_body(lease)
           }),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :claim_lease_comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :claim_lease_comment_create_failed}
    end
  end

  defp claim_lease_comment_body(%ClaimLease{} = lease) do
    ["## Symphony Claim Lease", "", ClaimLease.render(lease)]
    |> Enum.join("\n")
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
