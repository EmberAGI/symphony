defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec close_work_admission(Conn.t(), map()) :: Conn.t()
  def close_work_admission(conn, params) do
    if loopback_request?(conn),
      do: update_work_admission(conn, params, :close),
      else: error_response(conn, 403, "loopback_required", "Work admission mutations require loopback")
  end

  @spec open_work_admission(Conn.t(), map()) :: Conn.t()
  def open_work_admission(conn, params) do
    if loopback_request?(conn),
      do: update_work_admission(conn, params, :open),
      else: error_response(conn, 403, "loopback_required", "Work admission mutations require loopback")
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp update_work_admission(conn, %{"generation" => generation}, action) do
    result =
      case action do
        :close -> SymphonyElixir.Orchestrator.close_work_admission(orchestrator(), generation)
        :open -> SymphonyElixir.Orchestrator.open_work_admission(orchestrator(), generation)
      end

    work_admission_response(conn, result)
  end

  defp update_work_admission(conn, _params, _action) do
    error_response(conn, 400, "invalid_generation", "Generation is invalid")
  end

  defp loopback_request?(%Conn{remote_ip: {127, _b, _c, _d}}), do: true
  defp loopback_request?(%Conn{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp loopback_request?(%Conn{remote_ip: {0, 0, 0, 0, 0, 65_535, 32_512, 1}}), do: true
  defp loopback_request?(_conn), do: false

  defp work_admission_response(conn, {:ok, payload}), do: json(conn, payload)

  defp work_admission_response(conn, {:error, :invalid_generation}) do
    error_response(conn, 400, "invalid_generation", "Generation is invalid")
  end

  defp work_admission_response(conn, {:error, :execution_generation_mismatch}) do
    error_response(
      conn,
      409,
      "execution_generation_mismatch",
      "Target generation does not match this process"
    )
  end

  defp work_admission_response(conn, {:error, :execution_generation_unavailable}) do
    error_response(
      conn,
      503,
      "execution_generation_unavailable",
      "Execution generation is unavailable"
    )
  end

  defp work_admission_response(conn, {:error, :work_admission_generation_mismatch}) do
    error_response(
      conn,
      409,
      "work_admission_generation_mismatch",
      "Target generation does not match the work admission marker"
    )
  end

  defp work_admission_response(conn, {:error, :marker_unavailable}) do
    error_response(conn, 503, "work_admission_marker_unavailable", "Work admission marker is unavailable")
  end

  defp work_admission_response(conn, {:error, :unavailable}) do
    error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
