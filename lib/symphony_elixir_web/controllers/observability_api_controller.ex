defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, params) do
    case resolve_orchestrator(params) do
      nil -> error_response(conn, 503, "no_project", "No active project")
      orch -> json(conn, Presenter.state_payload(orch, snapshot_timeout_ms()))
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier} = params) do
    case resolve_orchestrator(params) do
      nil ->
        error_response(conn, 503, "no_project", "No active project")

      orch ->
        case Presenter.issue_payload(issue_identifier, orch, snapshot_timeout_ms()) do
          {:ok, payload} ->
            json(conn, payload)

          {:error, :issue_not_found} ->
            error_response(conn, 404, "issue_not_found", "Issue not found")
        end
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, params) do
    case resolve_orchestrator(params) do
      nil ->
        error_response(conn, 503, "no_project", "No active project")

      orch ->
        case Presenter.refresh_payload(orch) do
          {:ok, payload} ->
            conn
            |> put_status(202)
            |> json(payload)

          {:error, :unavailable} ->
            error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
        end
    end
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

  defp resolve_orchestrator(params) do
    project_id = Map.get(params, "project")
    SymphonyElixir.ProjectLookup.orchestrator(project_id)
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
