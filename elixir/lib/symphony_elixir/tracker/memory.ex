defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker.ClaimLease

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    issues = issue_entries()
    send_event({:memory_tracker_fetch_candidate_issues, Enum.map(issues, & &1.id)})
    {:ok, issues}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    send_event({:memory_tracker_fetch_issue_states_by_ids, issue_ids})
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    with :ok <- maybe_fail_mutation(:comment) do
      send_event({:memory_tracker_comment, issue_id, body})
      :ok
    end
  end

  @spec upsert_claim_lease(String.t(), map()) ::
          {:ok, ClaimLease.t() | nil} | {:error, term()}
  def upsert_claim_lease(issue_id, lease_attrs) do
    lease =
      lease_attrs
      |> Map.put(:issue_id, issue_id)
      |> ClaimLease.new()

    send_event({:memory_tracker_claim_lease, issue_id, lease})
    {:ok, lease}
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    with :ok <- maybe_fail_mutation(:state) do
      send_event({:memory_tracker_state_update, issue_id, state_name})
      :ok
    end
  end

  @spec add_issue_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_issue_label(issue_id, label_name) do
    with :ok <- maybe_fail_mutation(:label) do
      send_event({:memory_tracker_label_add, issue_id, label_name})
      :ok
    end
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp maybe_fail_mutation(kind) when kind in [:comment, :label, :state] do
    case Application.get_env(:symphony_elixir, :memory_tracker_fail_mutations, %{}) do
      failures when is_map(failures) ->
        case Map.get(failures, kind) || Map.get(failures, Atom.to_string(kind)) do
          nil -> :ok
          reason -> {:error, reason}
        end

      failures when is_list(failures) ->
        if kind in failures or Atom.to_string(kind) in failures do
          {:error, :memory_tracker_mutation_failed}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
