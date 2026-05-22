#!/usr/bin/env bash
#
# Discover available Claude models from the GitHub Copilot API
# and generate a litellm_config.yaml with the correct model entries.
#
# Usage: ./discover-models.sh [--dry-run]
#
# Prerequisites:
#   - LiteLLM must have authenticated with Copilot at least once
#     (run start.sh first, or manually authenticate)
#   - jq, curl
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/litellm_config.yaml"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

# --- Token acquisition ---

TOKEN_DIR="${GITHUB_COPILOT_TOKEN_DIR:-${HOME}/.config/litellm/github_copilot}"
API_KEY_FILE="${TOKEN_DIR}/api-key.json"
ACCESS_TOKEN_FILE="${TOKEN_DIR}/access-token"

get_copilot_session_token() {
    local access_token=""
    local api_key_json=""

    # Try cached session token first (check expiry)
    if [[ -f "$API_KEY_FILE" ]]; then
        local expires_at
        expires_at=$(jq -r '.expires_at // 0' "$API_KEY_FILE" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        if (( expires_at > now )); then
            jq -r '.token' "$API_KEY_FILE"
            return 0
        fi
    fi

    # Need to refresh — get access token
    if [[ -f "$ACCESS_TOKEN_FILE" ]]; then
        access_token=$(cat "$ACCESS_TOKEN_FILE")
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        access_token="$GITHUB_TOKEN"
    else
        echo "Error: No Copilot access token found." >&2
        echo "Run start.sh first to authenticate, or set GITHUB_TOKEN." >&2
        return 1
    fi

    # Exchange access token for Copilot session token
    api_key_json=$(curl -sf --max-time 10 \
        -H "Authorization: token ${access_token}" \
        -H "editor-version: vscode/1.103.1" \
        -H "editor-plugin-version: copilot/1.155.0" \
        -H "user-agent: GithubCopilot/1.155.0" \
        "https://api.github.com/copilot_internal/v2/token") || {
        echo "Error: Failed to get Copilot session token." >&2
        echo "Your access token may be invalid. Re-run start.sh to re-authenticate." >&2
        return 1
    }

    # Cache the session token
    mkdir -p "$TOKEN_DIR"
    echo "$api_key_json" > "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"

    echo "$api_key_json" | jq -r '.token'
}

# --- Model discovery ---

echo "Fetching available models from Copilot API..."

SESSION_TOKEN=$(get_copilot_session_token) || exit 1

MODELS_JSON=$(curl -sf --max-time 15 \
    -H "Authorization: Bearer ${SESSION_TOKEN}" \
    -H "editor-version: vscode/1.103.1" \
    -H "Copilot-Integration-Id: vscode-chat" \
    "https://api.githubcopilot.com/models") || {
    echo "Error: Failed to fetch models from Copilot API." >&2
    exit 1
}

# Filter to Claude models
CLAUDE_MODELS=$(echo "$MODELS_JSON" | jq -c '[.data[] | select(.vendor == "Anthropic") | {
    id: .id,
    name: .name,
    max_input: .capabilities.limits.max_context_window_tokens,
    max_output: .capabilities.limits.max_output_tokens,
    preview: .preview
}]')

MODEL_COUNT=$(echo "$CLAUDE_MODELS" | jq 'length')
echo "Found ${MODEL_COUNT} Claude model(s):"
echo "$CLAUDE_MODELS" | jq -r '.[] | "  \(.id) — \(.name) (input: \(.max_input), output: \(.max_output))"'

# --- Generate config ---

generate_config() {
    cat <<'HEADER'
_templates:
  - litellm_params: &litellm_params
      extra_headers:
        editor-version: "vscode/1.103.1"
        Copilot-Integration-Id: "vscode-chat"

model_list:
HEADER

    # Generate entries from discovered models
    echo "$CLAUDE_MODELS" | jq -r '.[] | @base64' | while read -r entry; do
        local id name max_input max_output
        id=$(echo "$entry" | base64 -d | jq -r '.id')
        name=$(echo "$entry" | base64 -d | jq -r '.name')
        max_input=$(echo "$entry" | base64 -d | jq -r '.max_input')
        max_output=$(echo "$entry" | base64 -d | jq -r '.max_output')

        # Convert Copilot model ID (dots) to Claude Code model name (dashes)
        # e.g., claude-opus-4.6-1m -> claude-opus-4-6-1m
        local cc_name="${id//\./-}"

        cat <<EOF
  # ${name}
  - model_name: ${cc_name}
    model_info:
      max_input_tokens: ${max_input}
      max_output_tokens: ${max_output}
    litellm_params:
      <<: *litellm_params
      model: github_copilot/${id}
  - model_name: ${cc_name}*
    model_info:
      max_input_tokens: ${max_input}
      max_output_tokens: ${max_output}
    litellm_params:
      <<: *litellm_params
      model: github_copilot/${id}

EOF
    done

    # Add generic aliases (map to best available model in each tier)
    # Sort by max_input descending (prefer 1M), then by ID descending (prefer newest version)
    local opus_id sonnet_id haiku_id
    opus_id=$(echo "$CLAUDE_MODELS" | jq -r '[.[] | select(.id | startswith("claude-opus"))] | sort_by(.max_input, .id) | reverse | .[0].id // empty')
    sonnet_id=$(echo "$CLAUDE_MODELS" | jq -r '[.[] | select(.id | startswith("claude-sonnet"))] | sort_by(.max_input, .id) | reverse | .[0].id // empty')
    haiku_id=$(echo "$CLAUDE_MODELS" | jq -r '[.[] | select(.id | startswith("claude-haiku"))] | sort_by(.max_input, .id) | reverse | .[0].id // empty')

    if [[ -n "$opus_id" ]]; then
        local opus_input opus_output
        opus_input=$(echo "$CLAUDE_MODELS" | jq -r --arg id "$opus_id" '.[] | select(.id == $id) | .max_input')
        opus_output=$(echo "$CLAUDE_MODELS" | jq -r --arg id "$opus_id" '.[] | select(.id == $id) | .max_output')
        cat <<EOF
  # Generic alias: opus -> ${opus_id}
  - model_name: opus
    model_info:
      max_input_tokens: ${opus_input}
      max_output_tokens: ${opus_output}
    litellm_params:
      <<: *litellm_params
      model: github_copilot/${opus_id}

EOF
    fi

    if [[ -n "$sonnet_id" ]]; then
        local sonnet_input sonnet_output
        sonnet_input=$(echo "$CLAUDE_MODELS" | jq -r --arg id "$sonnet_id" '.[] | select(.id == $id) | .max_input')
        sonnet_output=$(echo "$CLAUDE_MODELS" | jq -r --arg id "$sonnet_id" '.[] | select(.id == $id) | .max_output')
        cat <<EOF
  # Generic alias: sonnet -> ${sonnet_id}
  - model_name: sonnet
    model_info:
      max_input_tokens: ${sonnet_input}
      max_output_tokens: ${sonnet_output}
    litellm_params:
      <<: *litellm_params
      model: github_copilot/${sonnet_id}

EOF
    fi

    if [[ -n "$haiku_id" ]]; then
        local haiku_input haiku_output
        haiku_input=$(echo "$CLAUDE_MODELS" | jq -r --arg id "$haiku_id" '.[] | select(.id == $id) | .max_input')
        haiku_output=$(echo "$CLAUDE_MODELS" | jq -r --arg id "$haiku_id" '.[] | select(.id == $id) | .max_output')
        cat <<EOF
  # Generic alias: haiku -> ${haiku_id}
  - model_name: haiku
    model_info:
      max_input_tokens: ${haiku_input}
      max_output_tokens: ${haiku_output}
    litellm_params:
      <<: *litellm_params
      model: github_copilot/${haiku_id}

EOF
    fi

    cat <<'FOOTER'
litellm_settings:
  drop_params: true
  modify_params: true
  telemetry: false
  turn_off_message_logging: true

general_settings:
  enable_anthropic_routes: true
  disable_spend_logs: true
  disable_error_logs: true
  max_parallel_requests: 4
FOOTER
}

if $DRY_RUN; then
    echo ""
    echo "--- Generated config (dry run) ---"
    generate_config
else
    generate_config > "$CONFIG_FILE"
    echo ""
    echo "Updated ${CONFIG_FILE} with ${MODEL_COUNT} Claude model(s)."
    echo "Restart the proxy to pick up the changes."
fi
