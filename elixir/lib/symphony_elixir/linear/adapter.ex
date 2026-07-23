defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker.ClaimLease
  alias SymphonyElixir.Tracker.EscalationMarker

  @escalation_label "Human Escalation"
  @escalation_state "Human Escalation"

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

  @spec ensure_irrecoverable_escalation(String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def ensure_irrecoverable_escalation(issue_id, attrs)
      when is_binary(issue_id) and is_map(attrs) do
    case EscalationMarker.new(attrs) do
      {:ok, marker} -> reconcile_irrecoverable_escalation(issue_id, marker)
      {:error, reason} -> {:error, reason}
    end
  end

  def ensure_irrecoverable_escalation(_issue_id, _attrs),
    do: {:error, :invalid_irrecoverable_escalation}

  defp reconcile_irrecoverable_escalation(issue_id, marker) do
    with_escalation_lock(issue_id, marker.key, fn ->
      case fetch_current_issue(issue_id) do
        {:ok, %Issue{} = issue} -> ensure_remote_escalation(issue_id, issue, marker)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec upsert_claim_lease(String.t(), map()) :: {:ok, ClaimLease.t() | nil} | {:error, term()}
  def upsert_claim_lease(issue_id, lease_attrs) when is_binary(issue_id) and is_map(lease_attrs) do
    lease =
      lease_attrs
      |> Map.put(:issue_id, issue_id)
      |> ClaimLease.new()

    with :ok <- write_claim_lease_comment(lease),
         {:ok, [refetched_issue | _]} <- client_module().fetch_issue_states_by_ids([issue_id]),
         candidates <- claim_lease_candidates(refetched_issue),
         %ClaimLease{} = verified <- verified_claim_lease(candidates, lease),
         :ok <- verify_exclusive_claim_lease_owner(candidates, verified) do
      {:ok, verified}
    else
      {:ok, []} -> {:error, :claim_lease_issue_not_found}
      false -> {:error, :claim_lease_ownership_verification_failed}
      nil -> {:error, :claim_lease_missing_after_upsert}
      {:error, :claim_lease_competing_owner} -> {:error, :claim_lease_competing_owner}
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

  defp fetch_current_issue(issue_id) do
    case client_module().fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _]} -> {:ok, issue}
      {:ok, []} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_fetch_failed}
    end
  end

  defp ensure_remote_escalation(issue_id, %Issue{} = issue, %EscalationMarker{} = marker) do
    {comment_status, errors} = ensure_remote_comment(issue_id, issue, marker)
    {label_status, errors} = ensure_remote_label(issue_id, issue, errors)
    {state_status, errors} = ensure_remote_state(issue_id, issue, errors)

    progress = %{
      key: marker.key,
      comment: comment_status,
      label: label_status,
      state: state_status
    }

    case errors do
      [] -> {:ok, progress}
      _ -> {:error, %{key: marker.key, progress: progress, errors: Enum.reverse(errors)}}
    end
  end

  defp ensure_remote_comment(issue_id, %Issue{} = issue, %EscalationMarker{} = marker) do
    if EscalationMarker.find(issue.comments, marker.key) do
      {:already_present, []}
    else
      case create_comment(issue_id, EscalationMarker.render(marker)) do
        :ok -> {:created, []}
        {:error, reason} -> {{:error, reason}, [comment: reason]}
      end
    end
  end

  defp ensure_remote_label(issue_id, %Issue{} = issue, errors) do
    if Enum.any?(issue.labels, &(normalize_label_name(&1) == normalize_label_name(@escalation_label))) do
      {:already_present, errors}
    else
      case add_issue_label(issue_id, @escalation_label) do
        :ok -> {:applied, errors}
        {:error, reason} -> {{:error, reason}, [{:label, reason} | errors]}
      end
    end
  end

  defp ensure_remote_state(issue_id, %Issue{} = issue, errors) do
    if normalize_label_name(issue.state) == normalize_label_name(@escalation_state) do
      {:already_present, errors}
    else
      case update_issue_state(issue_id, @escalation_state) do
        :ok -> {:applied, errors}
        {:error, reason} -> {{:error, reason}, [{:state, reason} | errors]}
      end
    end
  end

  defp with_escalation_lock(issue_id, key, fun) when is_function(fun, 0) do
    case :global.trans({{__MODULE__, issue_id, key}, self()}, fun) do
      :aborted -> {:error, :escalation_lock_failed}
      {:aborted, reason} -> {:error, {:escalation_lock_failed, reason}}
      result -> result
    end
  end

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

  defp normalize_label_name(_label_name), do: ""
end
