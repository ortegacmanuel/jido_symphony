defmodule SymphonyElixir.Jido do
  @moduledoc """
  Jido supervisor instance for Symphony.

  Provides DynamicSupervisor and Registry for all Jido agent processes
  (CoordinatorAgent, WorkerAgent, etc.). Non-agent infrastructure processes
  (WorkflowStore, Orchestrator, ProophboardBridge) are managed separately
  by ProjectSupervisor via ProjectRegistry.

  ## Usage

  Started as part of the shared infrastructure in Application:

      children = [
        SymphonyElixir.Jido,
        ...
      ]

  Then agents are started via:

      {:ok, pid} = SymphonyElixir.Jido.start_agent(
        Symphony.CoordinatorAgent,
        id: "coordinator-partner-middleware"
      )
  """

  use Jido, otp_app: :symphony_elixir
end
