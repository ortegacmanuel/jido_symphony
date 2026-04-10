defmodule SymphonyElixir.Coordinator.Actions.DecomposeComplexIssue do
  @moduledoc """
  LLM-assisted decomposition for non-event-model issues.

  Follows the open-multi-agent coordinator pattern: uses an LLM call to
  break a complex issue into ordered subtasks with dependency edges.

  ## When it runs

  For issues in `other_issues` (no `event-model-slice` label). Called after
  the slice pipeline completes, to handle bugs, features, and refactors.

  ## Heuristics

  - **Simple issue** (title < 200 chars, no complexity markers): pass through as-is
  - **Complex issue** (long description, "first...then", "step N", multiple concerns):
    decompose via LLM into subtask checklist

  ## LLM call

  Uses the Anthropic Messages API via Req. Requires `ANTHROPIC_API_KEY` env var.
  Falls back to pass-through if API is unavailable.

  ## State consumed

  - `:other_issues` — from FetchOpenIssues

  ## State produced

  - `:decomposed_issues` — list of `%{issue: original, subtasks: [subtask] | nil}`
    where subtask is `%{title: str, description: str, depends_on: [title]}`
  """

  use Jido.Action,
    name: "decompose_complex_issue",
    description: "Decomposes complex non-slice issues into subtasks via LLM",
    schema: [
      max_subtasks: [type: :integer, default: 8]
    ]

  require Logger

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-4-20250514"

  # Complexity heuristics (from open-multi-agent's short-circuit check)
  @max_simple_title_length 200
  @complexity_patterns ~r/(first.*then|step \d|in parallel|after that|once.*complete|phase \d|depends on)/i

  @impl true
  def run(params, context) do
    other_issues = context.state[:other_issues] || []
    project_id = context.state[:project_id]

    if other_issues == [] do
      {:ok, %{decomposed_issues: []}}
    else
      decomposed =
        Enum.map(other_issues, fn issue ->
          if simple_issue?(issue) do
            %{issue: issue, subtasks: nil}
          else
            case decompose_via_llm(issue, project_id, params.max_subtasks) do
              {:ok, subtasks} ->
                %{issue: issue, subtasks: subtasks}

              {:error, reason} ->
                Logger.warning(
                  "Coordinator[#{project_id}]: LLM decomposition failed for ##{issue["number"]}: #{inspect(reason)}, passing through"
                )

                %{issue: issue, subtasks: nil}
            end
          end
        end)

      {:ok, %{decomposed_issues: decomposed}}
    end
  end

  @doc "Returns true if the issue is simple enough to skip LLM decomposition."
  def simple_issue?(issue) do
    title = issue["title"] || ""
    body = issue["body"] || ""
    combined = title <> " " <> body

    String.length(title) < @max_simple_title_length &&
      !Regex.match?(@complexity_patterns, combined)
  end

  defp decompose_via_llm(issue, project_id, max_subtasks) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) || api_key == "" do
      {:error, :no_api_key}
    else
      prompt = build_decomposition_prompt(issue, project_id, max_subtasks)

      body =
        Jason.encode!(%{
          model: @model,
          max_tokens: 2048,
          messages: [
            %{role: "user", content: prompt}
          ],
          system:
            "You are a technical project coordinator. " <>
              "Decompose the given issue into ordered subtasks. " <>
              "Return ONLY a JSON array, no markdown fences, no explanation."
        })

      case Req.post(@anthropic_url,
             body: body,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", "2023-06-01"},
               {"content-type", "application/json"}
             ],
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: response_body}} ->
          parse_llm_response(response_body)

        {:ok, %{status: status, body: error_body}} ->
          {:error, {:api_error, status, error_body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp build_decomposition_prompt(issue, project_id, max_subtasks) do
    """
    Decompose this GitHub issue into ordered implementation subtasks.

    Project: #{project_id}
    Issue ##{issue["number"]}: #{issue["title"]}

    Description:
    #{issue["body"] || "No description"}

    Rules:
    - Maximum #{max_subtasks} subtasks
    - Each subtask should be independently implementable
    - Order by dependency: earlier tasks first
    - Use "depends_on" to reference prerequisite subtask titles
    - Keep titles short and actionable (imperative form)

    Return a JSON array:
    [
      {"title": "Create entity and migration", "description": "...", "depends_on": []},
      {"title": "Add command handler", "description": "...", "depends_on": ["Create entity and migration"]},
      ...
    ]
    """
  end

  defp parse_llm_response(%{"content" => [%{"text" => text} | _]}) do
    # Strip markdown fences if present
    cleaned =
      text
      |> String.replace(~r/^```json\s*\n?/, "")
      |> String.replace(~r/\n?```\s*$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, subtasks} when is_list(subtasks) ->
        parsed =
          Enum.map(subtasks, fn st ->
            %{
              title: st["title"] || "Untitled",
              description: st["description"] || "",
              depends_on: st["depends_on"] || []
            }
          end)

        {:ok, parsed}

      {:ok, _} ->
        {:error, :unexpected_json_shape}

      {:error, reason} ->
        {:error, {:json_parse, reason}}
    end
  end

  defp parse_llm_response(_other) do
    {:error, :unexpected_response_format}
  end
end
