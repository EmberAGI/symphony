defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker.ClaimLease
  alias SymphonyElixir.Tracker.EscalationMarker

  @escalation_store :symphony_elixir_memory_tracker_escalations
  @escalation_label "Human Escalation"
  @escalation_state "Human Escalation"

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    issues = issue_entries() |> Enum.map(&materialize_issue/1)
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
     issue_entries()
     |> Enum.map(&materialize_issue/1)
     |> Enum.filter(fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    send_event({:memory_tracker_fetch_issue_states_by_ids, issue_ids})
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     issue_entries()
     |> Enum.map(&materialize_issue/1)
     |> Enum.filter(fn %Issue{id: id} ->
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

  @spec ensure_irrecoverable_escalation(String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def ensure_irrecoverable_escalation(issue_id, attrs)
      when is_binary(issue_id) and is_map(attrs) do
    with {:ok, marker} <- EscalationMarker.new(attrs) do
      with_escalation_lock(issue_id, marker.key, fn ->
        ensure_escalation(issue_id, marker)
      end)
    end
  end

  def ensure_irrecoverable_escalation(_issue_id, _attrs),
    do: {:error, :invalid_irrecoverable_escalation}

  @spec upsert_claim_lease(String.t(), map()) ::
          {:ok, ClaimLease.t() | nil} | {:error, term()}
  def upsert_claim_lease(issue_id, lease_attrs) do
    with :ok <- maybe_fail_mutation(:claim_lease) do
      lease =
        lease_attrs
        |> Map.put(:issue_id, issue_id)
        |> ClaimLease.new()

      persist_claim_lease(issue_id, lease)
      send_event({:memory_tracker_claim_lease, issue_id, lease})
      {:ok, lease}
    end
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

  defp materialize_issue(%Issue{id: issue_id} = issue) do
    issue = materialize_claim_lease(issue)

    case Agent.get(memory_store(), &Map.get(&1, escalation_state_key(issue_id))) do
      %{comments: comments, labels: labels, state: state} ->
        %{issue | comments: comments, labels: labels, state: state}

      _ ->
        issue
    end
  end

  defp ensure_escalation(issue_id, %EscalationMarker{} = marker) do
    snapshot = escalation_snapshot(issue_id)
    {snapshot, comment_status, errors} = ensure_escalation_comment(issue_id, snapshot, marker)
    {snapshot, label_status, errors} = ensure_escalation_label(issue_id, snapshot, errors)
    {_snapshot, state_status, errors} = ensure_escalation_state(issue_id, snapshot, errors)

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

  defp ensure_escalation_comment(issue_id, snapshot, %EscalationMarker{} = marker) do
    if EscalationMarker.find(snapshot.comments, marker.key) do
      {snapshot, :already_present, []}
    else
      case maybe_fail_mutation(:comment) do
        :ok ->
          body = EscalationMarker.render(marker)
          comment = %{id: "memory-escalation-#{marker.key}", body: body}
          snapshot = %{snapshot | comments: [comment | snapshot.comments]}
          persist_escalation_snapshot(issue_id, snapshot)
          send_event({:memory_tracker_comment, issue_id, body})
          {snapshot, :created, []}

        {:error, reason} ->
          {snapshot, {:error, reason}, [comment: reason]}
      end
    end
  end

  defp ensure_escalation_label(issue_id, snapshot, errors) do
    if Enum.any?(snapshot.labels, &(normalize_state(&1) == normalize_state(@escalation_label))) do
      {snapshot, :already_present, errors}
    else
      case maybe_fail_mutation(:label) do
        :ok ->
          snapshot = %{snapshot | labels: [@escalation_label | snapshot.labels]}
          persist_escalation_snapshot(issue_id, snapshot)
          send_event({:memory_tracker_label_add, issue_id, @escalation_label})
          {snapshot, :applied, errors}

        {:error, reason} ->
          {snapshot, {:error, reason}, [{:label, reason} | errors]}
      end
    end
  end

  defp ensure_escalation_state(issue_id, snapshot, errors) do
    if normalize_state(snapshot.state) == normalize_state(@escalation_state) do
      {snapshot, :already_present, errors}
    else
      case maybe_fail_mutation(:state) do
        :ok ->
          snapshot = %{snapshot | state: @escalation_state}
          persist_escalation_snapshot(issue_id, snapshot)
          send_event({:memory_tracker_state_update, issue_id, @escalation_state})
          {snapshot, :applied, errors}

        {:error, reason} ->
          {snapshot, {:error, reason}, [{:state, reason} | errors]}
      end
    end
  end

  defp escalation_snapshot(issue_id) do
    base_snapshot =
      case Enum.find(issue_entries(), &(&1.id == issue_id)) do
        %Issue{} = issue ->
          %{comments: List.wrap(issue.comments), labels: List.wrap(issue.labels), state: issue.state}

        _ ->
          %{comments: [], labels: [], state: nil}
      end

    case Agent.get(memory_store(), &Map.get(&1, escalation_state_key(issue_id))) do
      stored_snapshot when is_map(stored_snapshot) ->
        Map.merge(base_snapshot, stored_snapshot)

      _ ->
        base_snapshot
    end
  end

  defp persist_escalation_snapshot(issue_id, snapshot) do
    Agent.update(memory_store(), &Map.put(&1, escalation_state_key(issue_id), snapshot))
    :ok
  end

  defp persist_claim_lease(issue_id, %ClaimLease{} = lease) do
    Agent.update(memory_store(), &Map.put(&1, claim_state_key(issue_id), lease))
    :ok
  end

  defp materialize_claim_lease(%Issue{id: issue_id} = issue) do
    case Agent.get(memory_store(), &Map.get(&1, claim_state_key(issue_id))) do
      %ClaimLease{} = lease -> %{issue | claim_lease: lease, claim_leases: [lease]}
      _ -> issue
    end
  end

  defp escalation_state_key(issue_id), do: {:escalation, memory_scope(), issue_id}
  defp claim_state_key(issue_id), do: {:claim, memory_scope(), issue_id}

  defp memory_scope do
    Application.get_env(:symphony_elixir, :memory_tracker_recipient, :default)
  end

  defp memory_store do
    case Process.whereis(@escalation_store) do
      nil ->
        case Agent.start(fn -> %{} end, name: @escalation_store) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start memory escalation store: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end

    @escalation_store
  end

  defp with_escalation_lock(issue_id, key, fun) when is_function(fun, 0) do
    case :global.trans({{__MODULE__, issue_id, key}, self()}, fun) do
      :aborted -> {:error, :escalation_lock_failed}
      {:aborted, reason} -> {:error, {:escalation_lock_failed, reason}}
      result -> result
    end
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp maybe_fail_mutation(kind) when kind in [:comment, :label, :state, :claim_lease] do
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
