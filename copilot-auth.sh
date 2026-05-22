#!/usr/bin/env bash
#
# Authenticate with GitHub Copilot using the device code flow.
# Caches the token so start.sh and discover-models.sh work immediately.
#
# This uses the same OAuth client ID as VS Code's Copilot extension,
# which is required for the Copilot internal API to issue session tokens.
#
set -euo pipefail

COPILOT_CLIENT_ID="Iv1.b507a08c87ecfe98"
TOKEN_DIR="${GITHUB_COPILOT_TOKEN_DIR:-${HOME}/.config/litellm/github_copilot}"
ACCESS_TOKEN_FILE="${TOKEN_DIR}/access-token"
API_KEY_FILE="${TOKEN_DIR}/api-key.json"

# --- Check if already authenticated ---

if [[ -f "$API_KEY_FILE" ]]; then
    expires_at=$(jq -r '.expires_at // 0' "$API_KEY_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    if (( expires_at > now )); then
        echo "Already authenticated (session token valid until $(date -r "$expires_at" 2>/dev/null || date -d "@$expires_at" 2>/dev/null || echo "expiry: $expires_at"))."
        echo "Run with --force to re-authenticate."
        if [[ "${1:-}" != "--force" ]]; then
            exit 0
        fi
        echo "Forcing re-authentication..."
    fi
fi

# --- Step 1: Request device code ---

echo "Requesting device code from GitHub..."

DEVICE_RESPONSE=$(curl -sf --max-time 10 \
    -X POST \
    -H "accept: application/json" \
    -H "content-type: application/json" \
    "https://github.com/login/device/code" \
    -d "{\"client_id\": \"$COPILOT_CLIENT_ID\", \"scope\": \"read:user\"}") || {
    echo "Error: Failed to request device code from GitHub." >&2
    exit 1
}

DEVICE_CODE=$(echo "$DEVICE_RESPONSE" | jq -r '.device_code')
USER_CODE=$(echo "$DEVICE_RESPONSE" | jq -r '.user_code')
VERIFICATION_URI=$(echo "$DEVICE_RESPONSE" | jq -r '.verification_uri')
INTERVAL=$(echo "$DEVICE_RESPONSE" | jq -r '.interval // 5')

if [[ -z "$DEVICE_CODE" || "$DEVICE_CODE" == "null" ]]; then
    echo "Error: Failed to get device code. Response: $DEVICE_RESPONSE" >&2
    exit 1
fi

# --- Step 2: User authenticates in browser ---

echo ""
echo "=========================================="
echo "  Open: $VERIFICATION_URI"
echo "  Code: $USER_CODE"
echo "=========================================="
echo ""

# Try to copy code to clipboard
if command -v pbcopy >/dev/null 2>&1; then
    echo -n "$USER_CODE" | pbcopy
    echo "(Code copied to clipboard)"
elif command -v xclip >/dev/null 2>&1; then
    echo -n "$USER_CODE" | xclip -selection clipboard
    echo "(Code copied to clipboard)"
fi

# Try to open browser
if command -v open >/dev/null 2>&1; then
    open "$VERIFICATION_URI"
elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$VERIFICATION_URI"
fi

echo "Waiting for authentication..."

# --- Step 3: Poll for access token ---

ACCESS_TOKEN=""
for attempt in $(seq 1 24); do
    sleep "$INTERVAL"

    POLL_RESPONSE=$(curl -sf --max-time 10 \
        -X POST \
        -H "accept: application/json" \
        -H "content-type: application/json" \
        "https://github.com/login/oauth/access_token" \
        -d "{\"client_id\": \"$COPILOT_CLIENT_ID\", \"device_code\": \"$DEVICE_CODE\", \"grant_type\": \"urn:ietf:params:oauth:grant-type:device_code\"}") || continue

    ERROR=$(echo "$POLL_RESPONSE" | jq -r '.error // empty')
    if [[ "$ERROR" == "authorization_pending" ]]; then
        continue
    elif [[ "$ERROR" == "slow_down" ]]; then
        INTERVAL=$((INTERVAL + 5))
        continue
    elif [[ -n "$ERROR" && "$ERROR" != "null" ]]; then
        echo "Error: $ERROR — $(echo "$POLL_RESPONSE" | jq -r '.error_description // empty')" >&2
        exit 1
    fi

    ACCESS_TOKEN=$(echo "$POLL_RESPONSE" | jq -r '.access_token // empty')
    if [[ -n "$ACCESS_TOKEN" ]]; then
        break
    fi
done

if [[ -z "$ACCESS_TOKEN" ]]; then
    echo "Error: Timed out waiting for authentication." >&2
    exit 1
fi

echo "GitHub authentication successful."

# --- Step 4: Exchange for Copilot session token ---

echo "Fetching Copilot session token..."

API_KEY_JSON=$(curl -sf --max-time 10 \
    -H "Authorization: token $ACCESS_TOKEN" \
    -H "accept: application/json" \
    -H "editor-version: vscode/1.85.1" \
    -H "editor-plugin-version: copilot/1.155.0" \
    -H "user-agent: GithubCopilot/1.155.0" \
    "https://api.github.com/copilot_internal/v2/token") || {
    echo "Error: Failed to get Copilot session token." >&2
    echo "Your GitHub account may not have Copilot access." >&2
    exit 1
}

if ! echo "$API_KEY_JSON" | jq -e '.token' >/dev/null 2>&1; then
    echo "Error: Copilot token response missing 'token' field." >&2
    echo "Response: $API_KEY_JSON" >&2
    echo "Your GitHub account may not have Copilot access." >&2
    exit 1
fi

# --- Step 5: Cache tokens ---

mkdir -p "$TOKEN_DIR"
echo "$ACCESS_TOKEN" > "$ACCESS_TOKEN_FILE"
echo "$API_KEY_JSON" > "$API_KEY_FILE"
chmod 700 "$TOKEN_DIR"
chmod 600 "$ACCESS_TOKEN_FILE" "$API_KEY_FILE"

echo ""
echo "Authentication complete. Tokens cached in $TOKEN_DIR"
echo "You can now run ./start.sh or ./discover-models.sh"
