defmodule SymphonyElixir.Coordinator.Actions do
  @moduledoc """
  Namespace for all coordinator action modules.

  Actions are Jido Action modules used in signal routes. Each is a pure
  function that transforms agent state. Side effects are described as directives.

  ## CoordinatorAgent poll pipeline

  1. `FetchOpenIssues` — fetch from GitHub, partition into slices vs other
  2. `TriageSlices` — LLM groups slices into DUs with project context (cached)
  3. `CoordinateIssues` — open-multi-agent pattern for non-slice issues
  4. `BuildTaskDAG` — resolve cross-DU deps, mark ready/blocked
  5. `DispatchReadyUnits` — emit DispatchDeliveryUnit directives

  ## ReviewAgent pipeline

  1. `FetchPRsAwaitingChanges` — find Symphony PRs with changes_requested
  2. `DispatchReviewFix` — emit DispatchReviewFix directives

  ## FeedbackAgent pipeline

  1. `AnalyzeReviewPatterns` — scan merged PRs for recurring review themes
  2. `ClassifyGuidanceGap` — LLM classifies missing/unclear/exists
  3. `ProposeGuidanceUpdate` — emit ProposeGuidanceUpdate directives

  ## DU lifecycle

  - `HandleDUCompleted` — unblock dependents
  - `HandleDUFailed` — cascade failure

  ## Legacy (available but not in main signal routes)

  - `ClassifySlicePattern` — deterministic pattern classification
  - `IdentifyDeliveryUnits` — deterministic Union-Find grouping
  - `DecomposeComplexIssue` — standalone LLM decomposition
  """
end
