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
    local cmd="$1" min_major="$2" min_minor="${3:-0}" label="$4"
    if ! has "$cmd"; then
        return 1
    fi
    local version
    version=$("$cmd" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local major="${version%%.*}"
    local minor="${version##*.}"
    if (( major < min_major )) || (( major == min_major && minor < min_minor )); then
        warn "$label version $version found, need $min_major.$min_minor+."
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
    if need_version node 18 0 "Node.js"; then
        info "Node.js $(node --version) found."
        return
    fi

    info "Installing Node.js..."
    if has brew; then
        brew install node
        # Homebrew may fail to link if stale files exist from previous installs
        if ! has node || ! need_version node 18 0 "Node.js"; then
            info "Linking Node.js (clearing stale files if needed)..."
            brew link --overwrite node 2>/dev/null || {
                warn "brew link failed. Trying cleanup..."
                brew unlink node 2>/dev/null || true
                brew link --overwrite node || fail "Could not link Node.js. Try: brew link --overwrite node"
            }
        fi
    elif has apt-get; then
        if ! has curl; then install_pkg curl; fi
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt-get install -y -qq nodejs
    else
        fail "Install Node.js 18+ manually: https://nodejs.org/"
    fi
}

# --- Python ---

# Python version bounds: 3.9+ required by LiteLLM, 3.13 max supported by PyO3
PYTHON_MIN_MINOR=9
PYTHON_MAX_MINOR=13

check_python_version() {
    local cmd="$1"
    if ! has "$cmd"; then return 1; fi
    local v
    v=$("$cmd" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local maj="${v%%.*}" min="${v##*.}"
    (( maj == 3 && min >= PYTHON_MIN_MINOR && min <= PYTHON_MAX_MINOR ))
}

find_compatible_python() {
    # Check default python3 first
    if check_python_version python3; then
        echo "python3"
        return 0
    fi
    # Check Homebrew paths
    for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if check_python_version "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    # Check versioned binaries (python3.13, python3.12, etc.)
    for minor in $(seq $PYTHON_MAX_MINOR -1 $PYTHON_MIN_MINOR); do
        for candidate in "python3.${minor}" "/opt/homebrew/bin/python3.${minor}" "/usr/local/bin/python3.${minor}"; do
            if check_python_version "$candidate"; then
                echo "$candidate"
                return 0
            fi
        done
    done
    return 1
}

install_python() {
    local found
    found=$(find_compatible_python) && {
        info "Python $($found --version 2>&1) found."
        PYTHON="$found"
        PIP="$found -m pip"
        return
    }

    info "Installing Python 3.${PYTHON_MAX_MINOR}..."
    if has brew; then
        brew install "python@3.${PYTHON_MAX_MINOR}"
        # Homebrew installs versioned binary
        for candidate in "/opt/homebrew/bin/python3.${PYTHON_MAX_MINOR}" "/usr/local/bin/python3.${PYTHON_MAX_MINOR}" "python3.${PYTHON_MAX_MINOR}"; do
            if check_python_version "$candidate"; then
                PYTHON="$candidate"
                PIP="$candidate -m pip"
                info "Using $PYTHON ($($PYTHON --version 2>&1))"
                return
            fi
        done
    else
        install_pkg python3
    fi

    # Final check
    found=$(find_compatible_python) && {
        PYTHON="$found"
        PIP="$found -m pip"
        return
    }

    fail "Python 3.${PYTHON_MIN_MINOR}-3.${PYTHON_MAX_MINOR} is required. Your Python may be too new (3.14+) or too old. Install Python 3.${PYTHON_MAX_MINOR}: brew install python@3.${PYTHON_MAX_MINOR}"
}

# Set default Python/pip commands (may be overridden by install_python)
PYTHON="python3"
PIP="pip3"

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
    local venv_dir="${SCRIPT_DIR}/.venv"

    if [[ -f "$venv_dir/bin/litellm" ]]; then
        info "LiteLLM found in venv."
        return
    fi

    info "Creating Python virtual environment..."
    $PYTHON -m venv "$venv_dir"

    info "Upgrading pip..."
    "$venv_dir/bin/pip" install --upgrade pip --quiet 2>/dev/null || true
    "$venv_dir/bin/pip" cache purge 2>/dev/null || true
    $PYTHON -m pip cache purge 2>/dev/null || true

    info "Installing LiteLLM..."
    "$venv_dir/bin/pip" install --no-cache-dir --quiet "litellm[proxy]"
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

# Ensure Xcode CLI tools are installed (needed to compile native Python deps)
if [[ "$(uname)" == "Darwin" ]]; then
    if ! xcode-select -p >/dev/null 2>&1; then
        info "Installing Xcode Command Line Tools..."
        xcode-select --install 2>/dev/null || true
        echo "Waiting for Xcode CLI tools installation to complete..."
        echo "Press Enter after the installer finishes."
        read -r
    fi
fi

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
