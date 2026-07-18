defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.ClaimLease
  alias SymphonyElixir.Tracker.ClaimLeaseReconciliation

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

  @add_label_mutation """
  mutation SymphonyAddIssueLabel($issueId: String!, $labelId: String!) {
    issueUpdate(id: $issueId, input: {addedLabelIds: [$labelId]}) {
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

  @label_lookup_query """
  query SymphonyResolveIssueLabelId($issueId: String!) {
    issue(id: $issueId) {
      labels {
        nodes {
          id
          name
        }
      }
      team {
        labels {
          nodes {
            id
            name
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

  @spec upsert_claim_lease(String.t(), map()) ::
          {:ok, ClaimLease.t() | nil}
          | {:ok, ClaimLease.t(), ClaimLeaseReconciliation.t()}
          | {:error, term()}
  def upsert_claim_lease(issue_id, lease_attrs) when is_binary(issue_id) and is_map(lease_attrs) do
    lease =
      lease_attrs
      |> Map.put(:issue_id, issue_id)
      |> ClaimLease.new()

    case write_claim_lease_comment(lease) do
      :ok ->
        verify_written_claim_lease(issue_id, lease)

      {:error, {:linear_api_request, transport_reason}} ->
        reconcile_ambiguous_claim_lease_write(issue_id, lease, transport_reason)

      {:error, reason} ->
        {:error, reason}
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

  @spec add_issue_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_issue_label(issue_id, label_name)
      when is_binary(issue_id) and is_binary(label_name) do
    with {:ok, label_id} <- resolve_label_id(issue_id, label_name),
         {:ok, response} <-
           client_module().graphql(@add_label_mutation, %{issueId: issue_id, labelId: label_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_label_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_label_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp verify_written_claim_lease(issue_id, %ClaimLease{} = lease) do
    with {:ok, [refetched_issue | _]} <- client_module().fetch_issue_states_by_ids([issue_id]),
         candidates <- claim_lease_candidates(refetched_issue),
         %ClaimLease{} = verified <- verified_claim_lease(candidates, lease),
         :ok <- verify_exclusive_claim_lease_owner(candidates, verified) do
      {:ok, verified}
    else
      {:ok, []} -> {:error, :claim_lease_issue_not_found}
      nil -> {:error, :claim_lease_missing_after_upsert}
      {:error, :claim_lease_competing_owner} -> {:error, :claim_lease_competing_owner}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :claim_lease_upsert_failed}
    end
  end

  defp reconcile_ambiguous_claim_lease_write(issue_id, %ClaimLease{} = lease, transport_reason) do
    mutation = if is_binary(lease.comment_id), do: :update, else: :create

    case client_module().fetch_issue_states_by_ids([issue_id]) do
      {:ok, [refetched_issue | _]} ->
        classify_ambiguous_claim_lease(mutation, transport_reason, refetched_issue, lease)

      _refetch_failure ->
        ambiguous_fail_closed(mutation, transport_reason, :refetch_failed)
    end
  end

  defp classify_ambiguous_claim_lease(mutation, transport_reason, refetched_issue, %ClaimLease{} = lease) do
    now = DateTime.utc_now()
    candidates = claim_lease_candidates(refetched_issue)
    exact = Enum.find(candidates, &exact_attempted_claim_lease?(&1, lease, now))

    blocking =
      Enum.filter(candidates, fn candidate ->
        candidate != exact and
          ClaimLease.active_or_recoverable?(candidate, now) and
          same_claim_lease_scope?(candidate, lease)
      end)

    competing = Enum.find(blocking, &(&1.holder != lease.holder))
    stale_same_holder = Enum.find(blocking, &(&1.holder == lease.holder))

    cond do
      malformed_claim_lease_marker?(refetched_issue) ->
        ambiguous_fail_closed(mutation, transport_reason, :malformed_lease)

      match?(%ClaimLease{}, competing) ->
        ambiguous_fail_closed(mutation, transport_reason, :competing_holder, competing)

      match?(%ClaimLease{}, stale_same_holder) ->
        ambiguous_fail_closed(mutation, transport_reason, :same_holder_different_run, stale_same_holder)

      match?(%ClaimLease{}, exact) ->
        {:ok, exact, ClaimLeaseReconciliation.confirmed(mutation, transport_reason, exact)}

      true ->
        ambiguous_fail_closed(mutation, transport_reason, :no_lease_found)
    end
  end

  defp ambiguous_fail_closed(mutation, transport_reason, outcome, lease \\ nil) do
    {:error, ClaimLeaseReconciliation.fail_closed(mutation, transport_reason, outcome, lease)}
  end

  defp exact_attempted_claim_lease?(%ClaimLease{} = candidate, %ClaimLease{} = attempted, now) do
    is_binary(attempted.holder) and is_binary(attempted.run_id) and
      candidate.holder == attempted.holder and
      candidate.run_id == attempted.run_id and
      candidate.role == attempted.role and
      exact_workspace_path_match?(candidate.workspace_path, attempted.workspace_path) and
      (is_nil(attempted.comment_id) or candidate.comment_id == attempted.comment_id) and
      ClaimLease.active_or_recoverable?(candidate, now)
  end

  defp exact_workspace_path_match?(left, right) when is_binary(left) and is_binary(right) do
    normalize_workspace_path(left) == normalize_workspace_path(right)
  end

  defp exact_workspace_path_match?(left, right), do: blank?(left) and blank?(right)

  defp malformed_claim_lease_marker?(refetched_issue) do
    refetched_issue
    |> Map.get(:comments)
    |> List.wrap()
    |> Enum.any?(fn comment ->
      is_binary(comment_body(comment)) and
        String.contains?(comment_body(comment), "symphony-claim-lease") and
        is_nil(ClaimLease.from_comment(comment))
    end)
  end

  defp comment_body(%{body: body}), do: body
  defp comment_body(%{"body" => body}), do: body
  defp comment_body(_comment), do: nil

  defp verified_claim_lease(candidates, %ClaimLease{} = lease) when is_list(candidates) do
    Enum.find(candidates, &same_claim_lease?(&1, lease))
  end

  defp claim_lease_candidates(refetched_issue) do
    leases =
      refetched_issue
      |> Map.get(:claim_leases, [])
      |> Enum.filter(&match?(%ClaimLease{}, &1))

    case Map.get(refetched_issue, :claim_lease) do
      %ClaimLease{} = lease -> [lease | leases]
      _ -> leases
    end
    |> Enum.uniq_by(&claim_lease_identity/1)
  end

  defp same_claim_lease?(%ClaimLease{} = left, %ClaimLease{} = right) do
    left.holder == right.holder and left.run_id == right.run_id and
      (is_nil(right.comment_id) or left.comment_id == right.comment_id)
  end

  defp verify_exclusive_claim_lease_owner(candidates, %ClaimLease{} = verified) when is_list(candidates) do
    now = DateTime.utc_now()

    competing_owner? =
      Enum.any?(candidates, fn
        %ClaimLease{} = candidate ->
          ClaimLease.active_or_recoverable?(candidate, now) and
            same_claim_lease_scope?(candidate, verified) and
            !same_claim_lease?(candidate, verified)

        _ ->
          false
      end)

    if competing_owner?, do: {:error, :claim_lease_competing_owner}, else: :ok
  end

  defp same_claim_lease_scope?(%ClaimLease{} = left, %ClaimLease{} = right) do
    role_scope_matches?(left.role, right.role) and workspace_scope_matches?(left.workspace_path, right.workspace_path)
  end

  defp role_scope_matches?(left, right), do: blank?(left) or blank?(right) or left == right

  defp workspace_scope_matches?(left, right) do
    if blank?(left) or blank?(right) do
      true
    else
      normalize_workspace_path(left) == normalize_workspace_path(right)
    end
  end

  defp normalize_workspace_path(path) when is_binary(path), do: path |> Path.expand() |> Path.absname()

  defp blank?(value), do: !is_binary(value) or String.trim(value) == ""

  defp claim_lease_identity(%ClaimLease{} = lease) do
    {lease.comment_id, lease.role, lease.workspace_path, lease.holder, lease.run_id}
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

  defp resolve_label_id(issue_id, label_name) do
    with {:ok, response} <-
           client_module().graphql(@label_lookup_query, %{issueId: issue_id}),
         label_id when is_binary(label_id) <- find_label_id(response, label_name) do
      {:ok, label_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_not_found}
    end
  end

  defp find_label_id(response, label_name) do
    issue_labels = get_in(response, ["data", "issue", "labels", "nodes"]) || []
    team_labels = get_in(response, ["data", "issue", "team", "labels", "nodes"]) || []
    normalized_label_name = normalize_label_name(label_name)

    Enum.find_value(issue_labels ++ team_labels, fn
      %{"id" => id, "name" => name} when is_binary(id) and is_binary(name) ->
        if normalize_label_name(name) == normalized_label_name, do: id

      _ ->
        nil
    end)
  end

  defp normalize_label_name(label_name) when is_binary(label_name) do
    label_name
    |> String.trim()
    |> String.downcase()
  end
end
