#!/usr/bin/env bash
set -euo pipefail

PORT="${LITELLM_PORT:-4000}"
CONFIG="$(cd "$(dirname "$0")" && pwd)/litellm_config.yaml"

# Start LiteLLM proxy in background
litellm --config "$CONFIG" --port "$PORT" &
PROXY_PID=$!
trap "kill $PROXY_PID 2>/dev/null" EXIT

# Wait for proxy to be ready
for i in $(seq 1 30); do
  if curl -s "http://localhost:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "Proxy running on http://localhost:$PORT (PID $PROXY_PID)"
echo "Launching Claude Code..."

ANTHROPIC_BASE_URL="http://localhost:$PORT" \
ANTHROPIC_API_KEY="sk-copilot-bridge" \
claude "$@"
