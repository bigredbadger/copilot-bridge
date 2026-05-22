# Copilot Bridge

Route Claude Code through your GitHub Copilot subscription — no Anthropic API key needed.

This sets up a local [LiteLLM](https://github.com/BerriAI/litellm) proxy that translates Claude Code's Anthropic API calls into GitHub Copilot API calls. You get Claude models (Opus, Sonnet, Haiku) powered by your existing Copilot access.

## Prerequisites

- **GitHub Copilot** subscription (Individual, Business, or Enterprise) with Claude model access
- **macOS or Linux** (Windows via WSL should work too)

## Quick Start

```bash
git clone https://github.com/bigredbadger/copilot-bridge.git
cd copilot-bridge
./setup.sh
```

That's it. `setup.sh` handles everything:
1. Installs prerequisites (Node.js, Python, jq, LiteLLM, Claude Code)
2. Authenticates with GitHub Copilot (opens browser for one-time device code flow)
3. Discovers available Claude models and generates the proxy config

Then launch:

```bash
./start.sh
```

### Manual setup (if you prefer)

```bash
pip install litellm
npm install -g @anthropic-ai/claude-code
./copilot-auth.sh          # Authenticate with Copilot
./discover-models.sh       # Generate model config
./start.sh                 # Launch
```

### Manual launch (without the wrapper)

```bash
# Terminal 1: start the proxy
litellm --config litellm_config.yaml --port 4000

# Terminal 2: start Claude Code
ANTHROPIC_BASE_URL=http://localhost:4000 \
ANTHROPIC_AUTH_TOKEN=sk-anything \
claude
```

The `ANTHROPIC_AUTH_TOKEN` value is arbitrary — LiteLLM handles real auth via your Copilot token. Using `AUTH_TOKEN` (not `API_KEY`) bypasses Claude Code's login prompt.

## Authentication

`copilot-auth.sh` authenticates using the same OAuth device code flow as VS Code's Copilot extension. It:

1. Opens your browser to `github.com/login/device`
2. Copies a one-time code to your clipboard
3. Exchanges the authorization for a Copilot session token
4. Caches tokens in `~/.config/litellm/github_copilot/`

Tokens are refreshed automatically by LiteLLM. Re-run `./copilot-auth.sh --force` if you need to re-authenticate.

## Auto-discovering models

Copilot's available models change over time. To refresh your config:

```bash
./discover-models.sh
```

This queries the Copilot API, filters to Claude models, and regenerates `litellm_config.yaml` with correct model IDs, context windows, and output limits. It also creates generic aliases (`opus`, `sonnet`, `haiku`).

Preview without overwriting:

```bash
./discover-models.sh --dry-run
```

Refresh automatically on startup:

```bash
AUTO_DISCOVER=1 ./start.sh
```

## Choosing a model

Use Claude Code's `/model` command to switch. Run `discover-models.sh` to see what's available.

Or launch with a specific model:

```bash
./start.sh --model claude-sonnet-4-6
```

## Configuration

- **Port:** Set `LITELLM_PORT` env var (default: `4000`)
- **Models:** Run `./discover-models.sh` to refresh, or edit `litellm_config.yaml` manually

## How it works

```
Claude Code  →  LiteLLM proxy (localhost:4000)  →  GitHub Copilot API
              (Anthropic API format)              (translates to Copilot format)
```

LiteLLM's `github_copilot/` provider handles the protocol translation. The `extra_headers` in the config mimic a VS Code Copilot Chat client, which is required for the Copilot API to serve Claude models.

## Troubleshooting

**"No healthy deployments"** — LiteLLM can't authenticate with Copilot. Run `./copilot-auth.sh` to re-authenticate.

**Claude models not available** — Not all Copilot plans include Claude. Check your [Copilot settings](https://github.com/settings/copilot) to verify Claude models are enabled.

**Port already in use** — Another process is using port 4000. Set `LITELLM_PORT=4001` or kill the existing process.

**discover-models.sh fails** — Run `./copilot-auth.sh` first to get a valid token.

## License

MIT
