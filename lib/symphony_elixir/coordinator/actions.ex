defmodule SymphonyElixir.Coordinator.Actions do
  @moduledoc """
  Namespace for all CoordinatorAgent actions.

  Actions are pure functions that transform agent state.
  Side effects are described as directives.

  ## Poll pipeline (sequential)

  1. `FetchOpenIssues` — fetch from GitHub, partition into slices vs other
  2. `ClassifySlicePattern` — classify slices by pattern (SC→Internal, etc.)
  3. `IdentifyDeliveryUnits` — group by hard dependencies
  4. `BuildTaskDAG` — resolve cross-DU deps, mark ready/blocked
  5. `DispatchReadyUnits` — emit DispatchDeliveryUnit directives

  ## Lifecycle handlers

  - `HandleDUCompleted` — unblock dependents
  - `HandleDUFailed` — cascade failure
  """

  alias __MODULE__

  defdelegate fetch_open_issues(), to: Actions.FetchOpenIssues
  defdelegate classify_slice_pattern(), to: Actions.ClassifySlicePattern
  defdelegate identify_delivery_units(), to: Actions.IdentifyDeliveryUnits
  defdelegate build_task_dag(), to: Actions.BuildTaskDAG
  defdelegate dispatch_ready_units(), to: Actions.DispatchReadyUnits
  defdelegate handle_du_completed(), to: Actions.HandleDUCompleted
  defdelegate handle_du_failed(), to: Actions.HandleDUFailed
end
