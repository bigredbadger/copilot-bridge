#!/usr/bin/env bash
#
# Install all prerequisites for Copilot Bridge.
# Supports macOS (Homebrew) and Linux (apt/yum).
#
# What it installs:
#   - Node.js 18+ (if missing)
#   - Python 3.9+ and pip (if missing)
#   - jq (if missing)
#   - LiteLLM (via pip)
#   - Claude Code (via npm)
#
set -euo pipefail

# --- Helpers ---

info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
fail()  { echo "ERROR: $*" >&2; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }

need_version() {
    local cmd="$1" min_major="$2" label="$3"
    if ! has "$cmd"; then
        return 1
    fi
    local version
    version=$("$cmd" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local major="${version%%.*}"
    if (( major < min_major )); then
        warn "$label version $version found, need $min_major+."
        return 1
    fi
    return 0
}

# --- Detect package manager ---

install_pkg() {
    local pkg="$1"
    if has brew; then
        brew install "$pkg"
    elif has apt-get; then
        sudo apt-get update -qq && sudo apt-get install -y -qq "$pkg"
    elif has yum; then
        sudo yum install -y "$pkg"
    elif has dnf; then
        sudo dnf install -y "$pkg"
    else
        fail "No supported package manager found (brew, apt, yum, dnf). Install $pkg manually."
    fi
}

# --- Node.js ---

install_node() {
    if need_version node 18 "Node.js"; then
        info "Node.js $(node --version) found."
        return
    fi

    info "Installing Node.js..."
    if has brew; then
        brew install node
    elif has apt-get; then
        # NodeSource setup for Node 20 LTS
        if ! has curl; then install_pkg curl; fi
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt-get install -y -qq nodejs
    else
        fail "Install Node.js 18+ manually: https://nodejs.org/"
    fi
}

# --- Python ---

install_python() {
    if need_version python3 3 "Python"; then
        info "Python $(python3 --version 2>&1) found."
        return
    fi

    info "Installing Python..."
    install_pkg python3

    if ! has pip3 && ! has pip; then
        install_pkg python3-pip 2>/dev/null || true
    fi
}

# --- jq ---

install_jq() {
    if has jq; then
        info "jq found."
        return
    fi
    info "Installing jq..."
    install_pkg jq
}

# --- LiteLLM ---

install_litellm() {
    if has litellm; then
        info "LiteLLM found."
        return
    fi
    info "Upgrading pip..."
    python3 -m pip install --upgrade pip --quiet 2>/dev/null || true
    info "Installing LiteLLM..."
    pip3 install --quiet litellm || pip install --quiet litellm
}

# --- Claude Code ---

install_claude() {
    if has claude; then
        info "Claude Code found."
        return
    fi
    info "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
}

# --- Main ---

echo ""
echo "Copilot Bridge - Setup"
echo "======================"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

install_node
install_python
install_jq
install_litellm
install_claude

echo ""
info "All prerequisites installed."
echo ""

# Authenticate with GitHub Copilot
info "Authenticating with GitHub Copilot..."
"${SCRIPT_DIR}/copilot-auth.sh"

# Discover available models
info "Discovering available models..."
"${SCRIPT_DIR}/discover-models.sh"

echo ""
echo "Setup complete. Run ./start.sh to launch Claude Code."
echo ""
