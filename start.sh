#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${LITELLM_PORT:-4000}"
CONFIG="${SCRIPT_DIR}/litellm_config.yaml"
VENV_DIR="${SCRIPT_DIR}/.venv"
PID_FILE="${SCRIPT_DIR}/.litellm.pid"
LOG_FILE="${SCRIPT_DIR}/.litellm.log"

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
    curl -s --max-time 2 "http://localhost:$PORT/health" >/dev/null 2>&1
}

if proxy_running; then
    echo "Proxy already running on http://localhost:$PORT"
else
    # Clean up stale PID file
    if [[ -f "$PID_FILE" ]]; then
        old_pid=$(cat "$PID_FILE")
        if ! kill -0 "$old_pid" 2>/dev/null; then
            rm -f "$PID_FILE"
        fi
    fi

    echo "Starting proxy on port $PORT..."

    # Start LiteLLM proxy as a detached background process
    nohup $LITELLM --config "$CONFIG" --port "$PORT" > "$LOG_FILE" 2>&1 &
    PROXY_PID=$!
    disown $PROXY_PID 2>/dev/null || true
    echo "$PROXY_PID" > "$PID_FILE"

    # Wait for proxy to be ready (show progress)
    ready=false
    for i in $(seq 1 60); do
        if ! kill -0 "$PROXY_PID" 2>/dev/null; then
            echo "Error: Proxy failed to start. Check $LOG_FILE for details." >&2
            tail -20 "$LOG_FILE" >&2
            rm -f "$PID_FILE"
            exit 1
        fi
        if proxy_running; then
            ready=true
            break
        fi
        printf "."
        sleep 1
    done
    echo ""

    if $ready; then
        echo "Proxy started on http://localhost:$PORT (PID $PROXY_PID)"
    else
        echo "Error: Proxy did not become ready in 60s. Check $LOG_FILE" >&2
        tail -20 "$LOG_FILE" >&2
        exit 1
    fi
fi

echo "Launching Claude Code..."

ANTHROPIC_BASE_URL="http://localhost:$PORT" \
ANTHROPIC_AUTH_TOKEN="sk-copilot-bridge" \
claude "$@"
