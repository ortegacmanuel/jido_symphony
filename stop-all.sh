#!/bin/bash
# Stop all Symphony instances

echo "🛑 Stopping Symphony instances..."
lsof -ti:4009 2>/dev/null | xargs kill -9 2>/dev/null || true
lsof -ti:4010 2>/dev/null | xargs kill -9 2>/dev/null || true
echo "✅ Stopped"
