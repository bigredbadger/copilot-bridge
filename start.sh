#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${LITELLM_PORT:-4000}"
CONFIG="${SCRIPT_DIR}/litellm_config.yaml"

# Optional: refresh model list from Copilot API before starting
if [[ "${AUTO_DISCOVER:-}" == "1" ]]; then
  echo "Discovering available models..."
  "${SCRIPT_DIR}/discover-models.sh" || echo "Warning: model discovery failed, using existing config."
fi

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
