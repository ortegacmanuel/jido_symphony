defmodule SymphonyElixir.Coordinator.Actions.ClassifyGuidanceGap do
  @moduledoc """
  For each detected review pattern, classifies whether the guidance
  already covers it or if there's a gap.

  ## Classification

  - `:rule_missing` — No rule exists for this pattern. Need to add one.
  - `:rule_unclear` — Rule exists but agents still violate it. Need to strengthen.
  - `:rule_exists` — Rule exists and is clear. Agent comprehension issue (investigate).

  Uses LLM to compare detected patterns against current CLAUDE.md and
  deep-review rules to determine if the guidance is adequate.

  ## State consumed

  - `:review_patterns` — from AnalyzeReviewPatterns

  ## State produced

  - `:guidance_gaps` — list of `%{theme, classification, current_rule, suggestion, frequency}`
  """

  use Jido.Action,
    name: "classify_guidance_gap",
    description: "Classifies whether review patterns are covered by existing guidance",
    schema: []

  require Logger

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-4-20250514"

  @impl true
  def run(_params, context) do
    patterns = context.state[:review_patterns] || []
    project_id = context.state[:project_id]

    if patterns == [] do
      {:ok, %{guidance_gaps: []}}
    else
      case classify_gaps(patterns, project_id) do
        {:ok, gaps} ->
          actionable = Enum.reject(gaps, fn g -> g.classification == :rule_exists end)

          Logger.info(
            "Coordinator[#{project_id}]: found #{length(actionable)} guidance gaps " <>
              "out of #{length(patterns)} patterns"
          )

          {:ok, %{guidance_gaps: gaps}}

        {:error, reason} ->
          Logger.error("Coordinator[#{project_id}]: gap classification failed: #{inspect(reason)}")
          {:ok, %{guidance_gaps: []}}
      end
    end
  end

  defp classify_gaps(patterns, project_id) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) || api_key == "" do
      # Fallback: keyword-based heuristic (no LLM)
      {:ok, Enum.map(patterns, &classify_heuristic/1)}
    else
      classify_via_llm(patterns, project_id, api_key)
    end
  end

  defp classify_via_llm(patterns, _project_id, api_key) do
    patterns_summary =
      Enum.map_join(patterns, "\n\n", fn p ->
        examples = Enum.join(p.example_comments, "\n  - ")

        """
        Theme: #{p.theme} (seen in #{p.frequency} PRs)
        Example comments:
          - #{examples}
        """
      end)

    prompt = """
    You are analyzing recurring code review feedback patterns to determine
    if the project's AI coding guidance needs updating.

    For each pattern below, classify it as:
    - "rule_missing" — No rule covers this. Suggest a new rule.
    - "rule_unclear" — A rule likely exists but is too vague. Suggest how to strengthen.
    - "rule_exists" — Rule is clear, agent just didn't follow it.

    Also provide: which file should be updated (CLAUDE.md, ai_docs/critical-rules.md,
    or .claude/skills/deep-review/SKILL.md), and the specific rule text to add or modify.

    Patterns:
    #{patterns_summary}

    Return ONLY a JSON array:
    [
      {
        "theme": "domain_purity",
        "classification": "rule_unclear",
        "target_file": "CLAUDE.md",
        "current_rule_summary": "Domain exceptions must be transport-agnostic",
        "suggestion": "Add specific examples: no HTTP status codes (200, 404, 500), no Response objects, no $statusCode in Domain exceptions"
      }
    ]
    """

    body =
      Jason.encode!(%{
        model: @model,
        max_tokens: 2048,
        messages: [%{role: "user", content: prompt}],
        system:
          "You are a code quality expert analyzing guidance gaps. " <>
            "Return only valid JSON, no markdown fences."
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
        parse_classification_response(text, patterns)

      {:ok, %{status: status}} ->
        Logger.warning("Guidance gap LLM call failed with status #{status}, falling back to heuristic")
        {:ok, Enum.map(patterns, &classify_heuristic/1)}

      {:error, _reason} ->
        {:ok, Enum.map(patterns, &classify_heuristic/1)}
    end
  end

  defp parse_classification_response(text, patterns) do
    cleaned =
      text
      |> String.replace(~r/^```json\s*\n?/, "")
      |> String.replace(~r/\n?```\s*$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, items} when is_list(items) ->
        gaps =
          Enum.map(items, fn item ->
            pattern = Enum.find(patterns, fn p -> to_string(p.theme) == item["theme"] end)

            %{
              theme: String.to_atom(item["theme"] || "unknown"),
              classification: String.to_atom(item["classification"] || "rule_missing"),
              target_file: item["target_file"],
              current_rule: item["current_rule_summary"],
              suggestion: item["suggestion"],
              frequency: if(pattern, do: pattern.frequency, else: 0),
              prs: if(pattern, do: pattern.prs, else: [])
            }
          end)

        {:ok, gaps}

      _ ->
        {:ok, Enum.map(patterns, &classify_heuristic/1)}
    end
  end

  # Simple heuristic when LLM is unavailable
  defp classify_heuristic(pattern) do
    %{
      theme: pattern.theme,
      classification: :rule_unclear,
      target_file: suggest_target_file(pattern.theme),
      current_rule: nil,
      suggestion: "Review pattern '#{pattern.theme}' seen in #{pattern.frequency} PRs. Strengthen existing rules or add new ones.",
      frequency: pattern.frequency,
      prs: pattern.prs
    }
  end

  defp suggest_target_file(theme) when theme in [:domain_purity, :exception_hierarchy, :method_visibility, :entity_coupling, :cqrs_violation] do
    "CLAUDE.md"
  end

  defp suggest_target_file(theme) when theme in [:test_coverage, :test_placement] do
    "ai_docs/testing.md"
  end

  defp suggest_target_file(:git_hygiene), do: "CLAUDE.md"
  defp suggest_target_file(:duplication), do: "ai_docs/critical-rules.md"
  defp suggest_target_file(_), do: ".claude/skills/deep-review/SKILL.md"
end
