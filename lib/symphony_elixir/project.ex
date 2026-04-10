defmodule SymphonyElixir.Project do
  @moduledoc """
  Represents a project managed by Symphony.

  Each project has its own WORKFLOW.md, tracker, workspace, and agent pool.
  Projects are independent — no cross-project dependencies.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          workflow_path: Path.t(),
          status: :active | :stopped | :error
        }

  @enforce_keys [:id, :workflow_path]
  defstruct [:id, :workflow_path, status: :active]

  @doc "Creates a new Project struct."
  @spec new(String.t(), Path.t()) :: t()
  def new(id, workflow_path) when is_binary(id) and is_binary(workflow_path) do
    %__MODULE__{id: id, workflow_path: workflow_path}
  end
end
