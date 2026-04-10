defmodule SymphonyElixirWeb.IssuesLive do
  @moduledoc """
  LiveView for browsing and creating issues in the underlying tracker.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Tracker

  @refresh_ms 5_000

  @impl true
  def mount(params, _session, socket) do
    project_id = params["project"] || default_project()

    if connected?(socket), do: schedule_refresh()

    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:current_project, project_id)
      |> assign(:issues, load_issues())
      |> assign(:filter, "all")
      |> assign(:form, to_form(%{"title" => "", "description" => "", "type" => "task", "priority" => "", "labels" => ""}))
      |> assign(:flash_msg, nil)
      |> assign(:creating, false)
      |> assign(:current_path, "/issues")

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_issues, socket) do
    schedule_refresh()
    {:noreply, assign(socket, :issues, load_issues())}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, assign(socket, :filter, status)}
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :creating, !socket.assigns.creating)}
  end

  @impl true
  def handle_event("create_issue", %{"title" => title} = params, socket) when title != "" do
    attrs = %{
      title: String.trim(title),
      description: blank_to_nil(params["description"]),
      type: blank_to_nil(params["type"]),
      priority: blank_to_nil(params["priority"]),
      labels: blank_to_nil(params["labels"])
    }

    case Tracker.create_issue(attrs) do
      {:ok, _issue} ->
        socket =
          socket
          |> assign(:issues, load_issues())
          |> assign(:form, to_form(%{"title" => "", "description" => "", "type" => "task", "priority" => "", "labels" => ""}))
          |> assign(:creating, false)
          |> put_flash(:info, "Issue created: #{attrs.title}")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create issue: #{inspect(reason)}")}
    end
  end

  def handle_event("create_issue", _params, socket) do
    {:noreply, put_flash(socket, :error, "Title is required")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Issue Tracker</p>
            <h1 class="hero-title">Issues</h1>
            <p class="hero-copy">
              View and create issues in the underlying tracker. Issues are automatically picked up by the orchestrator.
            </p>
          </div>
          <div class="status-stack">
          </div>
        </div>
      </header>

      <.flash_messages flash={@flash} />

      <section class="section-card" style="margin-bottom: 1.5rem;">
        <div class="section-header" style="display: flex; justify-content: space-between; align-items: center;">
          <div>
            <h2 class="section-title">Create issue</h2>
            <p class="section-copy">Add a new issue for agents to work on.</p>
          </div>
          <button
            phx-click="toggle_form"
            style={"padding: 0.5rem 1rem; border-radius: 0.5rem; border: 1px solid #{if @creating, do: "#ef4444", else: "#60a5fa"}; background: transparent; color: #{if @creating, do: "#ef4444", else: "#60a5fa"}; cursor: pointer; font-size: 0.85rem;"}
          >
            <%= if @creating, do: "Cancel", else: "+ New Issue" %>
          </button>
        </div>

        <%= if @creating do %>
          <form phx-submit="create_issue" style="padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 0.75rem;">
            <div style="display: grid; grid-template-columns: 1fr 8rem 6rem; gap: 0.75rem;">
              <input
                type="text"
                name="title"
                value={@form[:title].value}
                placeholder="Issue title (required)"
                required
                style="padding: 0.5rem 0.75rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.9rem;"
              />
              <select
                name="type"
                style="padding: 0.5rem 0.5rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.85rem;"
              >
                <option value="task" selected={@form[:type].value == "task"}>Task</option>
                <option value="bug" selected={@form[:type].value == "bug"}>Bug</option>
                <option value="feature" selected={@form[:type].value == "feature"}>Feature</option>
              </select>
              <select
                name="priority"
                style="padding: 0.5rem 0.5rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.85rem;"
              >
                <option value="">Priority</option>
                <option value="0">P0 – Urgent</option>
                <option value="1">P1 – High</option>
                <option value="2">P2 – Medium</option>
                <option value="3">P3 – Low</option>
              </select>
            </div>
            <textarea
              name="description"
              placeholder="Description (optional — markdown supported)"
              rows="3"
              style="padding: 0.5rem 0.75rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.9rem; resize: vertical;"
            ><%= @form[:description].value %></textarea>
            <div style="display: flex; gap: 0.75rem; align-items: center;">
              <input
                type="text"
                name="labels"
                value={@form[:labels].value}
                placeholder="Labels (comma-separated)"
                style="flex: 1; padding: 0.5rem 0.75rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.9rem;"
              />
              <button
                type="submit"
                style="padding: 0.5rem 1.25rem; border-radius: 0.5rem; border: none; background: #60a5fa; color: #0f172a; cursor: pointer; font-weight: 600; font-size: 0.9rem;"
              >
                Create
              </button>
            </div>
          </form>
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-header" style="display: flex; justify-content: space-between; align-items: center;">
          <div>
            <h2 class="section-title">All issues</h2>
            <p class="section-copy"><%= length(filtered_issues(@issues, @filter)) %> issues shown</p>
          </div>
          <div style="display: flex; gap: 0.5rem;">
            <.filter_btn label="All" value="all" current={@filter} count={length(@issues)} />
            <.filter_btn label="Open" value="Todo" current={@filter} count={count_by_state(@issues, "Todo")} />
            <.filter_btn label="In Progress" value="In Progress" current={@filter} count={count_by_state(@issues, "In Progress")} />
            <.filter_btn label="Done" value="Done" current={@filter} count={count_by_state(@issues, "Done")} />
          </div>
        </div>

        <%= if filtered_issues(@issues, @filter) == [] do %>
          <p class="empty-state">No issues match the current filter.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 700px;">
              <colgroup>
                <col style="width: 7rem;" />
                <col />
                <col style="width: 7rem;" />
                <col style="width: 6rem;" />
                <col style="width: 10rem;" />
              </colgroup>
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Title</th>
                  <th>State</th>
                  <th>Priority</th>
                  <th>Labels</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={issue <- filtered_issues(@issues, @filter)}>
                  <td>
                    <span style="color: #60a5fa; font-family: monospace; font-size: 0.85rem;"><%= issue.id %></span>
                  </td>
                  <td>
                    <div style="display: flex; flex-direction: column; gap: 0.2rem;">
                      <span style="font-weight: 500;"><%= issue.title %></span>
                      <%= if issue.description do %>
                        <span style="color: #94a3b8; font-size: 0.8rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 400px;">
                          <%= String.slice(issue.description || "", 0, 120) %>
                        </span>
                      <% end %>
                    </div>
                  </td>
                  <td>
                    <span class={state_badge_class(issue.state)}><%= issue.state %></span>
                  </td>
                  <td class="numeric">
                    <%= if issue.priority, do: "P#{issue.priority}", else: "—" %>
                  </td>
                  <td>
                    <%= if issue.labels != [] do %>
                      <div style="display: flex; flex-wrap: wrap; gap: 0.25rem;">
                        <span :for={label <- issue.labels} style="padding: 0.1rem 0.5rem; border-radius: 9999px; background: #1e3a5f; color: #93c5fd; font-size: 0.75rem;">
                          <%= label %>
                        </span>
                      </div>
                    <% else %>
                      <span style="color: #475569;">—</span>
                    <% end %>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  # -- Components --

  defp flash_messages(assigns) do
    ~H"""
    <%= if info = Phoenix.Flash.get(@flash, :info) do %>
      <div style="margin: 0.75rem 0; padding: 0.75rem 1rem; border-radius: 0.5rem; background: #065f46; color: #a7f3d0; font-size: 0.9rem;" phx-click="lv:clear-flash" phx-value-key="info">
        ✓ <%= info %>
      </div>
    <% end %>
    <%= if error = Phoenix.Flash.get(@flash, :error) do %>
      <div style="margin: 0.75rem 0; padding: 0.75rem 1rem; border-radius: 0.5rem; background: #7f1d1d; color: #fca5a5; font-size: 0.9rem;" phx-click="lv:clear-flash" phx-value-key="error">
        ✗ <%= error %>
      </div>
    <% end %>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :current, :string, required: true
  attr :count, :integer, required: true

  defp filter_btn(assigns) do
    active = assigns.value == assigns.current

    assigns = assign(assigns, :active, active)

    ~H"""
    <button
      phx-click="filter"
      phx-value-status={@value}
      style={"padding: 0.35rem 0.75rem; border-radius: 0.375rem; border: 1px solid #{if @active, do: "#60a5fa", else: "#475569"}; background: #{if @active, do: "#1e3a5f", else: "transparent"}; color: #{if @active, do: "#93c5fd", else: "#94a3b8"}; cursor: pointer; font-size: 0.8rem;"}
    >
      <%= @label %> <span style="opacity: 0.7;">(<%= @count %>)</span>
    </button>
    """
  end

  # -- Helpers --

  defp load_issues do
    case Tracker.fetch_all_issues() do
      {:ok, issues} -> Enum.sort_by(issues, & &1.created_at, {:desc, DateTime})
      {:error, _} -> []
    end
  end

  defp filtered_issues(issues, "all"), do: issues
  defp filtered_issues(issues, state), do: Enum.filter(issues, &(&1.state == state))

  defp count_by_state(issues, state), do: Enum.count(issues, &(&1.state == state))

  defp state_badge_class(state) do
    base = "state-badge"

    case state do
      "Todo" -> "#{base} state-badge-todo"
      "In Progress" -> "#{base} state-badge-progress"
      "Done" -> "#{base} state-badge-done"
      _ -> base
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: String.trim(s)

  defp default_project do
    case SymphonyElixir.ProjectManager.list_projects() do
      [first | _] -> first
      [] -> nil
    end
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh_issues, @refresh_ms)
end
