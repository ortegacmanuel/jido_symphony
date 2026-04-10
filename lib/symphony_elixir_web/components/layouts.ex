defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script defer src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5/lib/xterm.min.js"></script>
        <script defer src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0/lib/addon-fit.min.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: {
                AutoScroll: {
                  mounted() {
                    this.scrollToBottom();
                    this.observer = new MutationObserver(() => this.scrollToBottom());
                    this.observer.observe(this.el, { childList: true, subtree: true });
                  },
                  scrollToBottom() {
                    this.el.scrollTop = this.el.scrollHeight;
                  },
                  destroyed() {
                    if (this.observer) this.observer.disconnect();
                  }
                },
                XtermSession: {
                  mounted() {
                    var self = this;
                    var initTerminal = function() {
                      if (!window.Terminal || !window.FitAddon) {
                        setTimeout(initTerminal, 100);
                        return;
                      }
                      self.term = new window.Terminal({
                        cursorBlink: false, disableStdin: true, convertEol: true,
                        fontSize: 13, fontFamily: "'JetBrains Mono', 'Fira Code', monospace",
                        theme: {
                          background: "#1e1e1e", foreground: "#d4d4d4",
                          black: "#1e1e1e", red: "#f44747", green: "#6a9955",
                          yellow: "#dcdcaa", blue: "#569cd6", magenta: "#c586c0",
                          cyan: "#4ec9b0", white: "#d4d4d4"
                        }
                      });
                      self.fitAddon = new window.FitAddon.FitAddon();
                      self.term.loadAddon(self.fitAddon);
                      self.term.open(self.el);
                      self.fitAddon.fit();
                      var initial = self.el.dataset.initial;
                      if (initial) self.term.write(initial);
                      self.handleEvent("xterm:write", function(payload) {
                        if (!payload.target || payload.target === self.el.id) {
                          self.term.write(payload.data);
                        }
                      });
                      self.handleEvent("xterm:clear", function(payload) {
                        if (!payload.target || payload.target === self.el.id) {
                          self.term.clear();
                        }
                      });
                      self._resizeObserver = new ResizeObserver(function() { self.fitAddon.fit(); });
                      self._resizeObserver.observe(self.el);
                    };
                    initTerminal();
                  },
                  destroyed() {
                    if (this._resizeObserver) this._resizeObserver.disconnect();
                    if (this.term) this.term.dispose();
                  }
                }
              }
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
        <link rel="stylesheet" href="/tool-renderers.css" />
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5/css/xterm.min.css" />
        <script src="https://cdn.tailwindcss.com"></script>
        <script>
          tailwind.config = {
            corePlugins: { preflight: false },
            theme: {
              extend: {
                colors: {
                  'base-content': '#e2e8f0',
                  'base-100': '#1e293b',
                  'base-200': '#0f172a',
                  'base-300': '#334155',
                  'neutral': '#0f172a',
                  'neutral-content': '#e2e8f0',
                  'success': '#34d399',
                  'error': '#f87171',
                  'warning': '#fbbf24',
                  'info': '#60a5fa',
                  'primary': '#60a5fa',
                  'secondary': '#a78bfa',
                  'accent': '#2dd4bf',
                }
              }
            }
          }
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    projects = SymphonyElixir.ProjectManager.list_projects()
    current_project = Map.get(assigns, :current_project, List.first(projects))

    assigns =
      assigns
      |> assign(:projects, projects)
      |> assign(:current_project, current_project)

    ~H"""
    <nav style="display: flex; align-items: center; gap: 1.5rem; padding: 0.6rem 1.5rem; background: #0f172a; border-bottom: 1px solid #1e293b; font-size: 0.85rem;">
      <a href="/" style="color: #e2e8f0; text-decoration: none; font-weight: 700; font-size: 0.95rem; margin-right: 0.5rem;">Symphony</a>

      <%= if length(@projects) > 0 do %>
        <span style="display: flex; align-items: center; gap: 0.4rem; color: #94a3b8;">
          <span style="font-size: 0.75rem;">PROJECT</span>
          <%= for project_id <- @projects do %>
            <a
              href={"/?project=#{project_id}"}
              style={"padding: 0.2rem 0.6rem; border-radius: 4px; text-decoration: none; font-size: 0.8rem; #{project_style(@current_project, project_id)}"}
            >
              {project_id}
            </a>
          <% end %>
        </span>
      <% end %>

      <span style="flex: 1;"></span>

      <a href={"/?project=#{@current_project}"} style={"color: #{nav_color(assigns, "/")}; text-decoration: none;"}>Dashboard</a>
      <a href={"/issues?project=#{@current_project}"} style={"color: #{nav_color(assigns, "/issues")}; text-decoration: none;"}>Issues</a>
      <a href="/projects/new" style={"color: #{nav_color(assigns, "/projects/new")}; text-decoration: none;"}>+ New</a>
    </nav>
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end

  defp nav_color(assigns, path) do
    current = Map.get(assigns, :current_path, "")
    if current == path, do: "#60a5fa", else: "#94a3b8"
  end

  defp project_style(current, project_id) do
    if current == project_id do
      "background: #1e3a5f; color: #60a5fa; font-weight: 600;"
    else
      "background: #1e293b; color: #94a3b8;"
    end
  end
end
