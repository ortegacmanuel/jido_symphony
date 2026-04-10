defmodule SymphonyElixir.Coordinator.Actions.ProposeGuidanceUpdate do
  @moduledoc """
  For each actionable guidance gap, emits a directive to create a
  meta-PR that updates the project's coding guidance.

  Only proposes updates for gaps classified as `:rule_missing` or
  `:rule_unclear`. Gaps classified as `:rule_exists` are logged
  as agent comprehension issues for investigation.

  ## State consumed

  - `:guidance_gaps` — from ClassifyGuidanceGap

  ## State produced

  - `:guidance_updates_proposed` — count of updates proposed
  """

  use Jido.Action,
    name: "propose_guidance_update",
    description: "Creates meta-PRs to improve coding guidance from review feedback",
    schema: []

  require Logger

  @impl true
  def run(_params, context) do
    gaps = context.state[:guidance_gaps] || []
    project_id = context.state[:project_id]

    actionable = Enum.filter(gaps, fn g -> g.classification in [:rule_missing, :rule_unclear] end)
    comprehension = Enum.filter(gaps, fn g -> g.classification == :rule_exists end)

    # Log comprehension issues (rule exists but agent didn't follow it)
    Enum.each(comprehension, fn g ->
      Logger.warning(
        "Coordinator[#{project_id}]: agent comprehension issue — " <>
          "#{g.theme} rule exists but was violated in #{length(g.prs)} PRs. " <>
          "Investigate why agents ignore this rule."
      )
    end)

    if actionable == [] do
      {:ok, %{guidance_updates_proposed: 0}}
    else
      directives =
        Enum.map(actionable, fn gap ->
          Logger.info(
            "Coordinator[#{project_id}]: proposing guidance update — " <>
              "#{gap.classification} for #{gap.theme} (#{gap.target_file})"
          )

          %SymphonyElixir.Coordinator.Directive.ProposeGuidanceUpdate{
            project_id: project_id,
            gap: gap
          }
        end)

      {:ok, %{guidance_updates_proposed: length(directives)}, directives}
    end
  end
end
