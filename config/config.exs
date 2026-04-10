import Config

config :phoenix, :json_library, Jason

# Jido agent runtime
config :symphony_elixir, SymphonyElixir.Jido,
  max_tasks: 2000,
  agent_pools: []

# Multi-project configuration.
# Each entry starts a ProjectSupervisor with its own Orchestrator, WorkflowStore, etc.
# If empty or not set, falls back to WORKFLOW_PATH env var (single-project backward compat).
#
# config :symphony_elixir, :projects, [
#   %{id: "partner-middleware", workflow_path: "/path/to/partner-middleware/WORKFLOW.md"},
#   %{id: "sentry-project", workflow_path: "/path/to/sentry-project/WORKFLOW.md"}
# ]

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [port: String.to_integer(System.get_env("PORT") || "4040")],
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: true
