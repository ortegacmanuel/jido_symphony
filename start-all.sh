#!/bin/bash
# Start Symphony for all projects simultaneously

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🚀 Starting Symphony for all projects"
echo "======================================="

# Kill any existing instances
lsof -ti:4009 2>/dev/null | xargs kill -9 2>/dev/null || true
lsof -ti:4010 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 1

# Get tokens for each account
gh auth switch --user ortegacmanuel 2>/dev/null
CONECTAZEN_TOKEN=$(gh auth token)
gh auth switch --user mortegaatcover 2>/dev/null
PARTNER_TOKEN=$(gh auth token)
gh auth switch --user ortegacmanuel 2>/dev/null

# ConectaZen (ortegacmanuel account)
echo ""
echo "📦 ConectaZen (port 4009)"
echo "   Repo: gazpachoteam/conecta_zen"
echo "   Account: ortegacmanuel"
(
  export WORKFLOW_PATH=/home/covertech/kodo/elixir/conecta_zen/WORKFLOW.md
  export GITHUB_REPO=gazpachoteam/conecta_zen
  export GH_TOKEN="$CONECTAZEN_TOKEN"
  export PROOPHBOARD_API_KEY=pb_ec3340ba027e447586379f84c46f0918
  export PROOPHBOARD_WORKSPACE_ID=c3415b98-69a1-4b4b-bb05-9fd2b6bae9ed
  export PROOPHBOARD_OUR_SYSTEM_LANES="Conectazen,conectazen,System Context"
  export PORT=4009
  mise exec -- mix phx.server
) > /tmp/symphony-conecta_zen.log 2>&1 &
PID1=$!
echo "   PID: $PID1"
echo "   Log: /tmp/symphony-conecta_zen.log"
echo "   Dashboard: http://localhost:4009"

# Partner Middleware (mortegaatcover account)
echo ""
echo "📦 Partner Middleware (port 4010)"
echo "   Repo: zenchef/partner-hub"
echo "   Account: mortegaatcover"
(
  export WORKFLOW_PATH=/home/covertech/kodo/partner-middleware/WORKFLOW.md
  export GITHUB_REPO=zenchef/partner-hub
  export GH_TOKEN="$PARTNER_TOKEN"
  export PORT=4010
  mise exec -- mix phx.server
) > /tmp/symphony-partner-middleware.log 2>&1 &
PID2=$!
echo "   PID: $PID2"
echo "   Log: /tmp/symphony-partner-middleware.log"
echo "   Dashboard: http://localhost:4010"

echo ""
echo "======================================="
echo "✅ Both instances running"
echo ""
echo "Dashboards:"
echo "  ConectaZen:          http://localhost:4009"
echo "  Partner Middleware:   http://localhost:4010"
echo ""
echo "Logs:"
echo "  tail -f /tmp/symphony-conecta_zen.log"
echo "  tail -f /tmp/symphony-partner-middleware.log"
echo ""
echo "To stop: ./stop-all.sh"
echo "======================================="
