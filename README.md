# Copilot Bridge

Route Claude Code through your GitHub Copilot subscription — no Anthropic API key needed.

This sets up a local [LiteLLM](https://github.com/BerriAI/litellm) proxy that translates Claude Code's Anthropic API calls into GitHub Copilot API calls. You get Claude models (Opus, Sonnet, Haiku) powered by your existing Copilot access.

## Prerequisites

- **GitHub Copilot** subscription (Individual, Business, or Enterprise) with Claude model access
- **macOS or Linux** (Windows via WSL should work too)
- **Node.js** 18+
- **jq** (for model discovery)

## Quick Start

### 1. Install dependencies

```bash
# LiteLLM proxy
pip install litellm

# Claude Code
npm install -g @anthropic-ai/claude-code
```

### 2. Authenticate with GitHub Copilot

LiteLLM's `github_copilot/` provider needs a valid Copilot token. The easiest way:

**Option A — VS Code (recommended):** Sign into GitHub Copilot in VS Code. LiteLLM reads the cached token automatically.

**Option B — Manual token:** Set `GITHUB_TOKEN` to a GitHub PAT with the `copilot` scope.

### 3. Launch

```bash
./start.sh
```

That's it. The script starts the LiteLLM proxy and launches Claude Code pointed at it.

On first launch, LiteLLM will prompt you with a device code to authenticate with GitHub if no cached token is found.

#### Manual launch (without the script)

```bash
# Terminal 1: start the proxy
litellm --config litellm_config.yaml --port 4000

# Terminal 2: start Claude Code
ANTHROPIC_BASE_URL=http://localhost:4000 \
ANTHROPIC_API_KEY=sk-anything \
claude
```

The `ANTHROPIC_API_KEY` value is arbitrary — LiteLLM handles real auth via your Copilot token.

## Auto-discovering models

The included config has a static model list, but Copilot's available models change over time. To update your config with whatever Claude models your Copilot subscription currently offers:

```bash
./discover-models.sh
```

This queries `https://api.githubcopilot.com/models`, filters to Anthropic models, and regenerates `litellm_config.yaml` with the correct model IDs, context windows, and output limits. It also creates generic aliases (`opus`, `sonnet`, `haiku`) pointing to the best available model in each tier.

Preview what would be generated without overwriting:

```bash
./discover-models.sh --dry-run
```

You can also run discovery automatically on startup:

```bash
AUTO_DISCOVER=1 ./start.sh
```

## Choosing a model

Use Claude Code's `/model` command to switch models. Run `discover-models.sh` to see what's available, or check the generated `litellm_config.yaml`.

Common models:

| Model | Name in `/model` |
|-------|-------------------|
| Claude Opus 4.6 (1M context) | `claude-opus-4-6-1m` |
| Claude Sonnet 4.6 | `claude-sonnet-4-6` |
| Claude Haiku 4.5 | `claude-haiku-4-5` |

Or launch with a specific model:

```bash
./start.sh --model claude-opus-4-6-1m
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

**"No healthy deployments"** — LiteLLM can't authenticate with Copilot. Make sure you're signed into Copilot in VS Code, or set `GITHUB_TOKEN`.

**Claude models not available** — Not all Copilot plans include Claude. Check your [Copilot settings](https://github.com/settings/copilot) to verify Claude models are enabled.

**Port already in use** — Another process is using port 4000. Set `LITELLM_PORT=4001` or kill the existing process.

**discover-models.sh fails** — You need a valid Copilot session token. Run `start.sh` first to authenticate (LiteLLM caches the token), then run discovery.

## License

MIT
