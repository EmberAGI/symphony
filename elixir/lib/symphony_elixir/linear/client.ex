defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000
  @repository_suggestion_confidence 0.9

  @issue_custom_field_values_supported_query """
  query SymphonyLinearIssueCustomFieldSupport {
    __type(name: "Issue") {
      fields {
        name
      }
    }
  }
  """

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        __CUSTOM_FIELD_VALUES__
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        __CUSTOM_FIELD_VALUES__
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @custom_field_values_selection """
        customFieldValues {
          nodes {
            value
            customField {
              name
            }
          }
        }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @repository_suggestions_query """
  query SymphonyLinearIssueRepositorySuggestions($issueId: String!, $candidateRepositories: [CandidateRepository!]!) {
    issueRepositorySuggestions(issueId: $issueId, candidateRepositories: $candidateRepositories) {
      suggestions {
        repositoryFullName
        hostname
        confidence
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    project_slug = tracker.project_slug

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(project_slug, tracker.active_states, assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      project_slug = tracker.project_slug

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(project_slug, normalized_states, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun, [])
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test(
          [String.t()],
          (String.t(), map() -> {:ok, map()} | {:error, term()}),
          [map()]
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun, repository_candidates)
      when is_list(issue_ids) and is_function(graphql_fun, 2) and is_list(repository_candidates) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, nil, graphql_fun, repository_candidates)
    end
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    query = linear_poll_query(&graphql/2)
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [], query)
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues, query) do
    with {:ok, body} <-
           graphql(query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter, &graphql/2, repository_candidates()) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc, query)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2, repository_candidates())
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun, repository_candidates)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    query = linear_issues_by_id_query(graphql_fun)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, repository_candidates, [], issue_order_index, query)
  end

  defp do_fetch_issue_states_page(
         [],
         _assignee_filter,
         _graphql_fun,
         _repository_candidates,
         acc_issues,
         issue_order_index,
         _query
       ) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(
         ids,
         assignee_filter,
         graphql_fun,
         repository_candidates,
         acc_issues,
         issue_order_index,
         query
       ) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(query, %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter, graphql_fun, repository_candidates) do
          updated_acc = prepend_page_issues(issues, acc_issues)

          do_fetch_issue_states_page(
            rest_ids,
            assignee_filter,
            graphql_fun,
            repository_candidates,
            updated_acc,
            issue_order_index,
            query
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp linear_poll_query(graphql_fun), do: query_with_optional_custom_field_values(@query, graphql_fun)

  defp linear_issues_by_id_query(graphql_fun), do: query_with_optional_custom_field_values(@query_by_ids, graphql_fun)

  defp query_with_optional_custom_field_values(query, graphql_fun) do
    selection =
      case issue_custom_field_values_supported?(graphql_fun) do
        true -> @custom_field_values_selection
        false -> ""
      end

    String.replace(query, "__CUSTOM_FIELD_VALUES__", selection)
  end

  defp issue_custom_field_values_supported?(graphql_fun) when is_function(graphql_fun, 2) do
    case graphql_fun.(@issue_custom_field_values_supported_query, %{}) do
      {:ok, %{"data" => %{"__type" => %{"fields" => fields}}}} when is_list(fields) ->
        Enum.any?(fields, fn
          %{"name" => "customFieldValues"} -> true
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(
         %{"data" => %{"issues" => %{"nodes" => nodes}}},
         assignee_filter,
         graphql_fun,
         repository_candidates
       ) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))
      |> maybe_enrich_repository_labels(repository_candidates)
      |> maybe_enrich_repository_suggestions(graphql_fun, repository_candidates)

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter, _graphql_fun, _repository_candidates) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter, _graphql_fun, _repository_candidates) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter,
         graphql_fun,
         repository_candidates
       ) do
    with {:ok, issues} <-
           decode_linear_response(
             %{"data" => %{"issues" => %{"nodes" => nodes}}},
             assignee_filter,
             graphql_fun,
             repository_candidates
           ) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      custom_fields: extract_custom_fields(issue),
      repository_source: repository_source(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_custom_fields(%{"customFields" => %{"nodes" => fields}}) when is_list(fields) do
    fields_to_map(fields)
  end

  defp extract_custom_fields(%{"customFieldValues" => %{"nodes" => fields}}) when is_list(fields) do
    fields_to_map(fields)
  end

  defp extract_custom_fields(%{"custom_fields" => custom_fields}) when is_map(custom_fields) do
    custom_fields
  end

  defp extract_custom_fields(_), do: %{}

  defp repository_source(%{"customFieldValues" => %{"nodes" => fields}}) when is_list(fields) do
    if repository_field_present?(fields), do: "linear_custom_field", else: nil
  end

  defp repository_source(%{"customFields" => %{"nodes" => fields}}) when is_list(fields) do
    if repository_field_present?(fields), do: "linear_custom_field", else: nil
  end

  defp repository_source(%{"custom_fields" => custom_fields}) when is_map(custom_fields) do
    if Map.has_key?(custom_fields, "Repository"), do: "linear_custom_field", else: nil
  end

  defp repository_source(_issue), do: nil

  defp repository_field_present?(fields) when is_list(fields) do
    fields
    |> fields_to_map()
    |> Map.has_key?("Repository")
  end

  defp fields_to_map(fields) when is_list(fields) do
    fields
    |> Enum.reduce(%{}, fn
      %{"name" => name, "value" => value}, acc when is_binary(name) ->
        Map.put(acc, name, value)

      %{"customField" => %{"name" => name}, "value" => value}, acc when is_binary(name) ->
        Map.put(acc, name, value)

      _field, acc ->
        acc
    end)
  end

  defp maybe_enrich_repository_suggestions(issues, graphql_fun, repository_candidates)
       when is_function(graphql_fun, 2) and is_list(repository_candidates) and repository_candidates != [] do
    Enum.map(issues, &maybe_enrich_repository_suggestion(&1, graphql_fun, repository_candidates))
  end

  defp maybe_enrich_repository_suggestions(issues, _graphql_fun, _repository_candidates), do: issues

  defp maybe_enrich_repository_labels(issues, repository_candidates)
       when is_list(issues) and is_list(repository_candidates) and repository_candidates != [] do
    repository_by_label =
      Enum.reduce(repository_candidates, %{}, fn
        %{"repositoryFullName" => repository}, acc when is_binary(repository) ->
          label_key = repository_label_key(repository)

          acc
          |> Map.put(label_key, repository)
          |> Map.put("repo:" <> label_key, repository)
          |> Map.put("repository:" <> label_key, repository)

        _candidate, acc ->
          acc
      end)

    Enum.map(issues, &maybe_enrich_repository_label(&1, repository_by_label))
  end

  defp maybe_enrich_repository_labels(issues, _repository_candidates), do: issues

  defp maybe_enrich_repository_label(%Issue{custom_fields: custom_fields, labels: labels} = issue, repository_by_label)
       when is_map(custom_fields) and is_list(labels) and is_map(repository_by_label) do
    if Map.has_key?(custom_fields, "Repository") do
      issue
    else
      labels
      |> Enum.map(&repository_label_key/1)
      |> Enum.find_value(&Map.get(repository_by_label, &1))
      |> case do
        nil ->
          issue

        repository ->
          %Issue{
            issue
            | custom_fields: Map.put(custom_fields, "Repository", repository),
              repository_source: "linear_label"
          }
      end
    end
  end

  defp maybe_enrich_repository_label(issue, _repository_by_label), do: issue

  defp repository_label_key(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp repository_label_key(_value), do: ""

  defp maybe_enrich_repository_suggestion(%Issue{id: issue_id, custom_fields: custom_fields} = issue, graphql_fun, candidates)
       when is_binary(issue_id) and is_map(custom_fields) do
    if Map.has_key?(custom_fields, "Repository") do
      issue
    else
      case fetch_repository_suggestion(issue_id, graphql_fun, candidates) do
        {:ok, repository} ->
          %Issue{
            issue
            | custom_fields: Map.put(custom_fields, "Repository", repository),
              repository_source: "linear_repository_suggestions"
          }

        :none ->
          issue
      end
    end
  end

  defp maybe_enrich_repository_suggestion(issue, _graphql_fun, _candidates), do: issue

  defp fetch_repository_suggestion(issue_id, graphql_fun, candidates) do
    case graphql_fun.(@repository_suggestions_query, %{issueId: issue_id, candidateRepositories: candidates}) do
      {:ok, %{"data" => %{"issueRepositorySuggestions" => %{"suggestions" => suggestions}}}}
      when is_list(suggestions) ->
        select_repository_suggestion(suggestions)

      _ ->
        :none
    end
  end

  defp select_repository_suggestion(suggestions) when is_list(suggestions) do
    matches =
      suggestions
      |> Enum.filter(fn
        %{"repositoryFullName" => repository, "confidence" => confidence}
        when is_binary(repository) and is_number(confidence) ->
          confidence >= @repository_suggestion_confidence

        _ ->
          false
      end)

    case matches do
      [%{"repositoryFullName" => repository}] -> {:ok, repository}
      _ -> :none
    end
  end

  defp repository_candidates do
    "SYMPHONY_LINEAR_REPOSITORY_CANDIDATES_JSON"
    |> System.get_env()
    |> parse_repository_candidates()
  end

  defp parse_repository_candidates(nil), do: []
  defp parse_repository_candidates(""), do: []

  defp parse_repository_candidates(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> normalize_repository_candidates(decoded)
      {:error, _reason} -> []
    end
  end

  defp normalize_repository_candidates(candidates) when is_list(candidates) do
    candidates
    |> Enum.flat_map(&normalize_repository_candidate/1)
  end

  defp normalize_repository_candidates(_candidates), do: []

  defp normalize_repository_candidate(%{"repositoryFullName" => repository, "hostname" => hostname})
       when is_binary(repository) and is_binary(hostname) do
    [%{"repositoryFullName" => repository, "hostname" => hostname}]
  end

  defp normalize_repository_candidate(repository) when is_binary(repository) do
    [%{"repositoryFullName" => repository, "hostname" => "github.com"}]
  end

  defp normalize_repository_candidate(_candidate), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
