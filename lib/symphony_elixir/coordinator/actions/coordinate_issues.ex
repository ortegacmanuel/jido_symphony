defmodule SymphonyElixir.Coordinator.Actions.CoordinateIssues do
  @moduledoc """
  open-multi-agent coordinator pattern for non-slice issues.

  For issues that are NOT event model slices (bugs, features, refactors),
  this action replicates what open-multi-agent's coordinator does:

  1. **Simple issue** (short, no complexity markers) → single task, dispatch immediately
  2. **Complex issue** → LLM decomposes into ordered subtask DAG with dependsOn edges

  The output merges with TriageSlices' delivery units into a unified DAG
  that BuildTaskDAG can process.

  ## Short-circuit heuristic (from open-multi-agent)

  Issues under 200 chars with no complexity patterns ("first...then", "step N",
  "in parallel", "after that") bypass the LLM and dispatch as single tasks.

  ## State consumed

  - `:other_issues` — from FetchOpenIssues (non-slice issues)
  - `:project_id` — for project context

  ## State produced

  - `:coordinated_tasks` — list of task groups (single task or subtask DAG)
    Each task: %{id, title, issue, subtasks: nil | [subtask], depends_on: []}
    Merged into delivery_units by the pipeline
  """

  use Jido.Action,
    name: "coordinate_issues",
    description: "open-multi-agent coordinator pattern for non-slice issues",
    schema: []

  require Logger

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-4-20250514"

  @max_simple_title_length 200
  @complexity_patterns ~r/(first.*then|step \d|in parallel|after that|once.*complete|phase \d|depends on|before.*after|multiple.*components)/i

  @impl true
  def run(_params, context) do
    other_issues = context.state[:other_issues] || []
    project_id = context.state[:project_id]
    delivery_units = context.state[:delivery_units] || %{}

    if other_issues == [] do
      {:ok, %{}}
    else
      {simple, complex} = Enum.split_with(other_issues, &simple_issue?/1)

      # Simple issues → individual DUs, ready immediately
      simple_units =
        Map.new(simple, fn issue ->
          du_id = "ISSUE-#{issue["number"]}"

          {du_id,
           %{
             id: du_id,
             name: issue["title"],
             slices: [issue],
             issue_numbers: [issue["number"]],
             rationale: "Simple issue, dispatched directly",
             status: :ready,
             depends_on: [],
             depends_on_unplanned: [],
             produces: [],
             consumes: [],
             patterns: [:direct]
           }}
        end)

      # Complex issues → LLM decomposition (open-multi-agent pattern)
      complex_units = decompose_complex_issues(complex, project_id)

      # Merge all into delivery_units
      merged = Map.merge(delivery_units, simple_units) |> Map.merge(complex_units)

      Logger.info(
        "Coordinator[#{project_id}]: coordinated #{length(simple)} simple + " <>
          "#{length(complex)} complex issues → #{map_size(merged) - map_size(delivery_units)} new DUs"
      )

      {:ok, %{delivery_units: merged}}
    end
  end

  defp simple_issue?(issue) do
    title = issue["title"] || ""
    body = issue["body"] || ""
    combined = title <> " " <> body

    String.length(title) < @max_simple_title_length &&
      !Regex.match?(@complexity_patterns, combined)
  end

  defp decompose_complex_issues([], _project_id), do: %{}

  defp decompose_complex_issues(issues, project_id) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) || api_key == "" do
      # Fallback: treat as simple (one DU per issue)
      Map.new(issues, fn issue ->
        du_id = "ISSUE-#{issue["number"]}"
        {du_id, simple_du(issue, du_id)}
      end)
    else
      project_context = load_project_context(project_id)

      issues
      |> Enum.map(fn issue -> {issue, decompose_one(issue, project_context, api_key)} end)
      |> Enum.flat_map(fn
        {issue, {:ok, subtasks}} ->
          build_subtask_dus(issue, subtasks)

        {issue, {:error, _reason}} ->
          du_id = "ISSUE-#{issue["number"]}"
          [{du_id, simple_du(issue, du_id)}]
      end)
      |> Map.new()
    end
  end

  defp decompose_one(issue, project_context, api_key) do
    prompt = """
    You are a technical coordinator. Decompose this GitHub issue into ordered
    implementation subtasks for a coding agent.

    ## Project Context
    #{String.slice(project_context, 0, 1500)}

    ## Issue ##{issue["number"]}: #{issue["title"]}
    #{issue["body"] || "No description"}

    ## Rules
    - Maximum 8 subtasks
    - Each subtask should be a coherent unit of work
    - Use "depends_on" to reference prerequisite subtask titles
    - If this is already simple enough for one task, return a single-item array
    - Titles should be imperative ("Create entity", "Add handler", not "Creating entity")

    Return ONLY a JSON array:
    [
      {"title": "...", "description": "...", "depends_on": []},
      {"title": "...", "description": "...", "depends_on": ["first task title"]}
    ]
    """

    body =
      Jason.encode!(%{
        model: @model,
        max_tokens: 2048,
        messages: [%{role: "user", content: prompt}],
        system:
          "You are a senior engineer decomposing work into implementable tasks. " <>
            "Return only valid JSON array, no markdown fences."
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
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        parse_subtasks(text)

      _ ->
        {:error, :api_call_failed}
    end
  end

  defp parse_subtasks(text) do
    cleaned =
      text
      |> String.replace(~r/^```json\s*\n?/, "")
      |> String.replace(~r/\n?```\s*$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, subtasks} when is_list(subtasks) and length(subtasks) > 0 ->
        parsed =
          Enum.map(subtasks, fn st ->
            %{
              title: st["title"] || "Untitled",
              description: st["description"] || "",
              depends_on: st["depends_on"] || []
            }
          end)

        {:ok, parsed}

      _ ->
        {:error, :bad_json}
    end
  end

  defp build_subtask_dus(parent_issue, subtasks) do
    if length(subtasks) == 1 do
      du_id = "ISSUE-#{parent_issue["number"]}"
      [{du_id, simple_du(parent_issue, du_id)}]
    else
      # Create one DU per subtask with dependency edges
      # Title-based dependsOn → resolved to DU IDs
      title_to_du = Map.new(subtasks, fn st ->
        {st.title, "ISSUE-#{parent_issue["number"]}-#{slug(st.title)}"}
      end)

      Enum.map(subtasks, fn st ->
        du_id = title_to_du[st.title]

        deps =
          st.depends_on
          |> Enum.flat_map(fn dep_title ->
            case Map.get(title_to_du, dep_title) do
              nil -> []
              dep_id -> [dep_id]
            end
          end)

        status = if deps == [], do: :ready, else: :blocked

        {du_id,
         %{
           id: du_id,
           name: st.title,
           slices: [parent_issue],
           issue_numbers: [parent_issue["number"]],
           rationale: "Subtask of ##{parent_issue["number"]}: #{st.description}",
           status: status,
           depends_on: deps,
           depends_on_unplanned: [],
           produces: [],
           consumes: [],
           patterns: [:decomposed]
         }}
      end)
    end
  end

  defp simple_du(issue, du_id) do
    %{
      id: du_id,
      name: issue["title"],
      slices: [issue],
      issue_numbers: [issue["number"]],
      rationale: "Single issue, dispatched directly",
      status: :ready,
      depends_on: [],
      depends_on_unplanned: [],
      produces: [],
      consumes: [],
      patterns: [:direct]
    }
  end

  defp slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 30)
  end

  defp load_project_context(project_id) do
    case SymphonyElixir.Config.current_workflow(project_id) do
      {:ok, %{prompt_template: prompt}} when is_binary(prompt) and prompt != "" -> prompt
      _ -> "No project context available."
    end
  end
end
