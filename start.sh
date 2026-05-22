#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${LITELLM_PORT:-4000}"
CONFIG="${SCRIPT_DIR}/litellm_config.yaml"
VENV_DIR="${SCRIPT_DIR}/.venv"
PID_FILE="${SCRIPT_DIR}/.litellm.pid"

# Use venv litellm if available, otherwise fall back to system
if [[ -f "$VENV_DIR/bin/litellm" ]]; then
    LITELLM="$VENV_DIR/bin/litellm"
elif command -v litellm >/dev/null 2>&1; then
    LITELLM="litellm"
else
    echo "Error: LiteLLM not found. Run ./setup.sh first." >&2
    exit 1
fi

# Optional: refresh model list from Copilot API before starting
if [[ "${AUTO_DISCOVER:-}" == "1" ]]; then
  echo "Discovering available models..."
  "${SCRIPT_DIR}/discover-models.sh" || echo "Warning: model discovery failed, using existing config."
fi

# Check if proxy is already running
proxy_running() {
    curl -s "http://localhost:$PORT/health" >/dev/null 2>&1
}

if proxy_running; then
    echo "Proxy already running on http://localhost:$PORT"
else
    # Check for stale PID file
    if [[ -f "$PID_FILE" ]]; then
        old_pid=$(cat "$PID_FILE")
        if ! kill -0 "$old_pid" 2>/dev/null; then
            rm -f "$PID_FILE"
        fi
    fi

    # Start LiteLLM proxy in background
    $LITELLM --config "$CONFIG" --port "$PORT" &
    PROXY_PID=$!
    echo "$PROXY_PID" > "$PID_FILE"

    # Wait for proxy to be ready
    for i in $(seq 1 30); do
        if proxy_running; then
            break
        fi
        sleep 1
    done

    echo "Proxy started on http://localhost:$PORT (PID $PROXY_PID)"
fi

echo "Launching Claude Code..."

ANTHROPIC_BASE_URL="http://localhost:$PORT" \
ANTHROPIC_AUTH_TOKEN="sk-copilot-bridge" \
claude "$@"
