---
status: Draft
created: 2026-05-22
author: Chuck Chen
---

# Spec: AgentBus — Real-Time Communication Relay for AI Agents

## Problem Statement

AI agents (Claude Code, Copilot CLI, Codex) operate in complete isolation. An agent on one machine has no way to communicate with an agent on another — even if they're working on the same problem for the same team. There's no way to ask another agent a question, share a discovery, or coordinate work in real-time.

## Objective

Build a lightweight, ephemeral message relay that enables AI agents to communicate across sessions, devices, models, surfaces, and users — with hierarchical multi-tenancy ensuring data isolation.

**What it is:** A real-time communication bus. Messages flow through, agents react.

**What it is not:** A knowledge store, task manager, or persistence layer. Those can be added later as extensions.

## Success Criteria

1. Agent A sends a message; Agent B receives it within 5 seconds
2. Works across Claude Code, Copilot CLI, Codex, VS Code extensions, web apps
3. User X's messages are never visible to User Y unless explicitly scoped
4. Supports 100+ concurrent agent connections
5. MCP integration: Claude Code agents connect with one config entry
6. Mid-turn capable: agents can discover new messages during active conversations
7. Zero persistent storage of message content at v1 (ephemeral relay)

## Non-Goals (v1)

- Message persistence or search (future extension)
- Task delegation or workflows (future extension)
- Knowledge graph or RAG (future extension)
- Agent discovery or capability registry (future extension)

## Architecture

### Two Viable Paths

| | Azure Web PubSub | NATS |
|---|---|---|
| **Latency** | 10-50ms | <1ms |
| **Managed** | Yes (Azure-native) | No (single binary, trivial deploy) |
| **Cost** | ~$49/mo per unit (100K conns) | Free (OSS) |
| **Channel hierarchy** | Group-based (flat, app-managed) | Native subject hierarchy (`org.team.user.>`) |
| **Auth** | JWT + server-side group auth | Built-in NKeys/JWT with account isolation |
| **Persistence add-on** | Must build separately | JetStream (built-in, toggle on) |
| **Best for** | Minimal ops, Azure-native | Lower latency, richer routing, future extensibility |

**Recommendation:** NATS. The subject hierarchy maps perfectly to multi-tenancy (`{org}.{team}.{user}.{channel}`), sub-millisecond latency is significantly better for agent responsiveness, JetStream provides a free persistence upgrade path, and it's a single binary with zero dependencies. Deploy as an Azure Container App.

### System Architecture

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌──────────┐
│ Claude Code  │  │ Copilot CLI  │  │   Codex     │  │ VS Code  │
│   (MCP)      │  │   (MCP)      │  │  (REST/WS)  │  │  (WS)    │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └────┬─────┘
       │                 │                 │               │
       ▼                 ▼                 ▼               ▼
┌──────────────────────────────────────────────────────────────────┐
│                      AgentBus API                                │
│                (FastAPI on Azure Container Apps)                  │
│                                                                  │
│  ┌──────────┐  ┌──────────────┐  ┌───────────┐  ┌────────────┐ │
│  │ MCP      │  │ WebSocket    │  │ REST      │  │ Auth       │ │
│  │ Server   │  │ Gateway      │  │ API       │  │ (JWT)      │ │
│  └────┬─────┘  └──────┬───────┘  └─────┬─────┘  └────────────┘ │
│       │               │               │                         │
│       ▼               ▼               ▼                         │
│  ┌──────────────────────────────────────────┐                   │
│  │            NATS Core (pub/sub)            │                   │
│  │     Subjects: {org}.{team}.{user}.{ch}   │                   │
│  └──────────────────────────────────────────┘                   │
└──────────────────────────────────────────────────────────────────┘
```

### Components

**1. NATS Core** — The relay backbone. Handles pub/sub with subject-based routing. No persistence (fire-and-forget). Subjects map to the tenancy hierarchy.

**2. AgentBus API (FastAPI)** — Thin API layer that:
- Authenticates requests (JWT validation)
- Authorizes pub/sub based on JWT claims (org/team/user scope)
- Bridges MCP ↔ NATS (MCP server maintains NATS subscription, pushes to agent via SSE)
- Exposes REST + WebSocket for non-MCP clients

**3. MCP Server** — The primary integration surface. Exposes tools to Claude Code / Copilot CLI agents. Bridges between MCP's Streamable HTTP transport and NATS subscriptions.

**4. Auth Service** — Issues JWTs with hierarchical claims. Simple API key → JWT exchange for agents.

## Channel Design

### Naming Convention

```
{org}.{team}.{user}.{channel}
```

Examples:
- `acme.platform.chuck.notifications` — Chuck's private channel
- `acme.platform.*.research` — Platform team's research channel (wildcard subscribe)
- `acme.*.*.announcements` — Org-wide announcements

NATS subject wildcards enable powerful subscription patterns:
- `*` matches one token: `acme.platform.*.updates` (all platform users' updates)
- `>` matches one or more: `acme.platform.>` (everything in platform team)

### Visibility Rules

Enforced at the API layer before publishing to NATS:

| Scope | Who can see | Subject pattern |
|-------|-------------|-----------------|
| `user` | Only sender | `{org}.{team}.{user}.{channel}` |
| `team` | All team members | `{org}.{team}.shared.{channel}` |
| `org` | All org members | `{org}.shared.shared.{channel}` |

## Message Format

```json
{
  "id": "msg_uuid",
  "type": "message|question|answer|event",
  "channel": "research",
  "sender": {
    "user": "chuck",
    "team": "platform",
    "org": "acme",
    "agent": "claude-code",
    "session": "sess_abc"
  },
  "content": "Found that PKCE is required for SPA auth flows",
  "tags": ["auth", "security"],
  "reply_to": null,
  "timestamp": "2026-05-22T10:30:00Z"
}
```

Lightweight, no persistence baggage. Future versions can add fields without breaking v1 clients.

## MCP Tools

| Tool | Description |
|------|-------------|
| `bus_send(channel, content, type?, tags?, scope?)` | Send a message to a channel |
| `bus_subscribe(pattern)` | Subscribe to channels (supports wildcards) |
| `bus_unsubscribe(pattern)` | Unsubscribe from channels |
| `bus_check()` | Poll for pending messages (explicit check) |
| `bus_who()` | List connected agents and what they're working on |
| `bus_ask(channel, question)` | Shorthand: send type=question |
| `bus_answer(message_id, answer)` | Shorthand: send type=answer with reply_to |

## Mid-Turn Message Delivery

MCP Streamable HTTP provides three mechanisms:

### 1. GET Listening Stream (Primary)

The MCP server opens a persistent SSE stream (`GET /mcp`). When messages arrive on subscribed NATS subjects, the server pushes them as MCP notifications over this stream. The agent sees them between tool calls.

### 2. Piggyback on Tool Responses

Every tool response includes a notification summary:

```json
{
  "result": "Message sent to research channel",
  "_pending": {
    "count": 2,
    "preview": "alice: 'Has anyone looked at the rate limiting approach?'"
  }
}
```

The agent naturally discovers pending messages when using any bus tool.

### 3. Explicit Poll

`bus_check()` returns all messages received since last check. Fallback for clients that don't support SSE push.

**Practical reality:** Whether an agent *reacts* to a pushed notification mid-turn depends on the client. Claude Code currently processes MCP notifications for logging but doesn't interrupt reasoning. The piggyback + explicit poll patterns are the reliable path today.

## Authentication

### Flow

1. Org admin registers at AgentBus, receives org API key
2. Admin creates team/user credentials (API keys or Entra ID mapping)
3. Agent connects with API key → receives JWT with claims:

```json
{
  "org": "acme",
  "team": "platform",
  "user": "chuck",
  "permissions": ["publish", "subscribe"],
  "exp": 1716422400
}
```

4. JWT scopes all pub/sub operations — API rejects out-of-scope access

### NATS Account Isolation

Each org maps to a NATS account. Cross-account messaging is impossible at the NATS level — defense in depth beyond JWT validation.

## Client Integration

| Client | Connection | Notes |
|--------|-----------|-------|
| Claude Code | MCP (Streamable HTTP) | Primary. Add to `.claude/settings.json` MCP config |
| Copilot CLI | MCP (same) | Same server, different client |
| Codex | REST API | POST to send, GET to poll, WebSocket for subscribe |
| VS Code ext | WebSocket | Direct connection to API gateway |
| Web dashboard | WebSocket/SSE | Standard web client |
| CI/automation | REST API | Fire-and-forget POST |

## Deployment (Azure)

```
Azure Container Apps
├── agentbus-api (FastAPI, 2+ replicas, auto-scale)
├── nats (NATS server, single node or 3-node cluster)
└── (future) nats-jetstream for persistence
```

Minimal infrastructure. NATS is a single binary. The API server is a Python container. Total cost: ~$30-50/mo at low scale.

## Extensibility Path

v1 is deliberately minimal — ephemeral relay only. Future versions add:

| Version | Feature | How |
|---------|---------|-----|
| v2 | **Message persistence** | Enable NATS JetStream. Messages stored with configurable TTL |
| v2 | **Search** | Add Azure AI Search index. Subscribe to JetStream and index messages |
| v3 | **Workflows** | Question→answer chains become multi-step workflows with state |
| v3 | **Agent registry** | Agents register capabilities. Bus routes questions to capable agents |
| v4 | **Knowledge graph** | Messages with `reply_to` form a graph. Vector embeddings for RAG |
| v4 | **A2A protocol** | Adopt Google A2A wire format for cross-vendor interop |

Each extension is additive — v1 clients continue to work without changes.

## Open Questions

1. **NATS deployment**: Single node or 3-node cluster for HA?
2. **Message buffering**: Buffer last N messages per channel for late-joining agents? (Short TTL, not persistence)
3. **Rate limiting**: Per-user, per-agent, or per-channel?
4. **Message size limit**: 1KB? 64KB? 1MB?
5. **Channel lifecycle**: Auto-create on first publish, or explicit creation?

## Implementation Plan

### Project Structure

```
copilot-bridge/
├── src/
│   ├── agentbus/
│   │   ├── __init__.py
│   │   ├── main.py                  # FastAPI app entry point
│   │   ├── config.py                # Settings (pydantic-settings)
│   │   ├── models.py                # Pydantic models (Message, Channel, etc.)
│   │   ├── auth/
│   │   │   ├── __init__.py
│   │   │   ├── jwt.py               # JWT creation/validation
│   │   │   ├── middleware.py         # FastAPI auth middleware
│   │   │   └── api_keys.py          # API key → JWT exchange
│   │   ├── nats/
│   │   │   ├── __init__.py
│   │   │   ├── client.py            # NATS connection manager
│   │   │   └── bridge.py            # Pub/sub bridge logic
│   │   ├── api/
│   │   │   ├── __init__.py
│   │   │   ├── rest.py              # REST endpoints (send, poll, who)
│   │   │   ├── websocket.py         # WebSocket gateway
│   │   │   └── health.py            # Health/readiness probes
│   │   ├── mcp/
│   │   │   ├── __init__.py
│   │   │   ├── server.py            # MCP Streamable HTTP handler
│   │   │   ├── tools.py             # MCP tool definitions (bus_send, etc.)
│   │   │   └── notifications.py     # SSE push / piggyback logic
│   │   ├── tenancy/
│   │   │   ├── __init__.py
│   │   │   ├── resolver.py          # JWT claims → NATS subject mapping
│   │   │   ├── admin.py             # Admin API (org/team/user CRUD)
│   │   │   └── accounts.py          # NATS account provisioning
│   │   └── sdk/
│   │       ├── python/
│   │       │   └── agentbus_client/  # Python SDK package
│   │       └── typescript/
│   │           └── agentbus-client/  # TypeScript SDK package
│   ├── cli/
│   │   └── agentbus_cli.py          # CLI test client
│   └── dashboard/
│       └── ...                      # Web dashboard (Phase 4)
├── deploy/
│   ├── Dockerfile                   # API server container
│   ├── docker-compose.yml           # Local dev (API + NATS)
│   ├── nats.conf                    # NATS server configuration
│   └── azure/
│       ├── bicep/                   # Azure Container Apps IaC
│       │   ├── main.bicep
│       │   ├── nats.bicep
│       │   └── api.bicep
│       └── deploy.sh                # Deployment script
├── tests/
│   ├── unit/
│   ├── integration/
│   └── e2e/
├── pyproject.toml
└── README.md
```

---

### Phase 1: Core Relay (MVP)

The goal is a working pub/sub relay: send a message via REST, receive it via WebSocket or polling. No MCP, no multi-tenancy — single-user, ephemeral relay.

#### Task 1.1: Project Scaffolding & NATS Setup

**Deliverable:** Runnable project with NATS server and FastAPI skeleton.

**Files:**
- `pyproject.toml` — Dependencies: `fastapi`, `uvicorn`, `nats-py`, `pydantic`, `pydantic-settings`, `python-jose[cryptography]`
- `src/agentbus/__init__.py`, `main.py`, `config.py`
- `deploy/nats.conf` — Single-node NATS config (port 4222, no auth initially)
- `deploy/docker-compose.yml` — NATS server + API server services
- `deploy/Dockerfile` — Python 3.12 slim, uvicorn entrypoint

**Dependencies:** None (first task).

**Complexity:** S

**Acceptance Criteria:**
- `docker compose up` starts NATS + API server
- `GET /health` returns `200 {"status": "ok", "nats": "connected"}`
- NATS is reachable on localhost:4222

#### Task 1.2: Message Models & NATS Bridge

**Deliverable:** Core message schema and NATS pub/sub wrapper.

**Files:**
- `src/agentbus/models.py` — `Message`, `Sender`, `MessageType` Pydantic models matching the spec's message format
- `src/agentbus/nats/client.py` — Connection manager (connect, reconnect, health check)
- `src/agentbus/nats/bridge.py` — `publish(subject, message)`, `subscribe(pattern, callback)`, `unsubscribe(sid)`, in-memory subscriber registry

**Dependencies:** Task 1.1

**Complexity:** S

**Acceptance Criteria:**
- Publish a message to a NATS subject, subscriber callback fires
- Message round-trips through JSON serialization without data loss
- Connection auto-reconnects after brief NATS restart

#### Task 1.3: JWT Authentication

**Deliverable:** API key → JWT exchange endpoint and auth middleware.

**Files:**
- `src/agentbus/auth/jwt.py` — `create_token(claims)`, `validate_token(token)` using HS256 with configurable secret
- `src/agentbus/auth/api_keys.py` — `POST /auth/token` endpoint: accepts API key, returns JWT with `org`, `team`, `user`, `permissions`, `exp` claims. For MVP, API keys are stored in config/env (no database).
- `src/agentbus/auth/middleware.py` — FastAPI dependency `get_current_user()` that extracts and validates Bearer JWT from Authorization header

**Dependencies:** Task 1.1

**Complexity:** S

**Acceptance Criteria:**
- `POST /auth/token` with valid API key returns JWT
- `POST /auth/token` with invalid key returns 401
- Protected endpoints reject requests without valid JWT
- JWT contains `org`, `team`, `user`, `permissions` claims

#### Task 1.4: REST API — Send & Poll

**Deliverable:** REST endpoints for publishing messages and polling.

**Files:**
- `src/agentbus/api/rest.py`:
  - `POST /channels/{channel}/messages` — Publish a message. Body: `{content, type?, tags?, scope?}`. Sender populated from JWT claims. Constructs NATS subject from JWT claims + channel name.
  - `GET /channels/{channel}/messages` — Poll for messages since last check. Returns buffered messages (in-memory, last 100 per channel, 5-min TTL).
  - `GET /who` — List currently connected agents (from subscriber registry).
- `src/agentbus/api/health.py` — `GET /health`, `GET /ready`

**Dependencies:** Tasks 1.2, 1.3

**Complexity:** M

**Acceptance Criteria:**
- POST a message, poll it back with GET — content matches
- Messages older than 5 minutes are not returned
- `/who` lists agents with active subscriptions
- All endpoints require valid JWT

#### Task 1.5: WebSocket Gateway

**Deliverable:** WebSocket endpoint for real-time subscribe/receive.

**Files:**
- `src/agentbus/api/websocket.py`:
  - `WS /ws` — Accepts connection with JWT (query param or first message). Client sends JSON commands: `{"action": "subscribe", "pattern": "research"}`, `{"action": "unsubscribe", "pattern": "research"}`. Server pushes messages as they arrive from NATS.

**Dependencies:** Tasks 1.2, 1.3

**Complexity:** M

**Acceptance Criteria:**
- Connect via WebSocket, subscribe to a channel
- Message published via REST appears on WebSocket within 1 second
- Multiple WebSocket clients on same channel all receive the message
- Disconnected clients are cleaned up (no leaked subscriptions)

#### Task 1.6: CLI Test Client

**Deliverable:** Command-line tool for sending and receiving messages.

**Files:**
- `src/cli/agentbus_cli.py` — Uses `argparse` or `click`:
  - `agentbus send <channel> <message> [--type] [--tags]`
  - `agentbus subscribe <pattern>` (WebSocket listener, prints messages)
  - `agentbus poll <channel>` (REST poll)
  - `agentbus who`
  - `agentbus auth --api-key <key>` (get JWT, cache in `~/.agentbus/token`)
  - Config: `--server` flag or `AGENTBUS_URL` env var

**Dependencies:** Tasks 1.4, 1.5

**Complexity:** S

**Acceptance Criteria:**
- Two CLI instances: one subscribes, other sends — message appears in real-time
- `agentbus who` shows connected agents
- Works against both local docker-compose and remote deployment

#### Task 1.7: Azure Container Apps Deployment

**Deliverable:** IaC and scripts for deploying to Azure.

**Files:**
- `deploy/azure/bicep/main.bicep` — Container Apps Environment, Log Analytics workspace
- `deploy/azure/bicep/nats.bicep` — NATS container app (internal ingress only, port 4222)
- `deploy/azure/bicep/api.bicep` — API container app (external ingress, port 8000, min 2 replicas, scale on HTTP concurrency)
- `deploy/azure/deploy.sh` — Build, push to ACR, deploy via Bicep

**Dependencies:** Tasks 1.1–1.5

**Complexity:** M

**Acceptance Criteria:**
- `./deploy/azure/deploy.sh` deploys working system to Azure
- API is accessible at public HTTPS endpoint
- NATS is internal only (not exposed externally)
- Health check passes on deployed instance
- CLI client works against deployed endpoint

---

### Phase 2: MCP Integration

Connect Claude Code and Copilot CLI via MCP protocol, so agents can use bus tools natively.

#### Task 2.1: MCP Server — Streamable HTTP Transport

**Deliverable:** MCP-compliant HTTP endpoint that handles tool listing and invocation.

**Files:**
- `src/agentbus/mcp/server.py`:
  - `POST /mcp` — Handles MCP JSON-RPC messages (`initialize`, `tools/list`, `tools/call`)
  - `GET /mcp` — SSE stream for server-initiated notifications (MCP listening stream)
  - Session management: track MCP session ID, associate with NATS subscriptions
- Use `mcp` Python SDK (`pip install mcp`) for protocol handling

**Dependencies:** Phase 1 complete

**Complexity:** M

**Acceptance Criteria:**
- MCP client can connect and list available tools
- `tools/list` returns all 7 bus tools with correct schemas
- Session lifecycle works (initialize → use → disconnect)

#### Task 2.2: MCP Tool Implementations

**Deliverable:** All 7 MCP tools wired to NATS.

**Files:**
- `src/agentbus/mcp/tools.py`:
  - `bus_send(channel, content, type?, tags?, scope?)` — Publish to NATS
  - `bus_subscribe(pattern)` — Create NATS subscription, attach to MCP session
  - `bus_unsubscribe(pattern)` — Remove subscription
  - `bus_check()` — Return buffered messages since last check
  - `bus_who()` — List connected agents
  - `bus_ask(channel, question)` — Shorthand for type=question
  - `bus_answer(message_id, answer)` — Shorthand for type=answer with reply_to

**Dependencies:** Task 2.1

**Complexity:** M

**Acceptance Criteria:**
- Each tool executes correctly via MCP protocol
- `bus_send` from MCP → received by REST/WS subscribers (and vice versa)
- `bus_check` returns only messages since last call (no duplicates)

#### Task 2.3: Mid-Turn Notification Patterns

**Deliverable:** Three notification delivery mechanisms.

**Files:**
- `src/agentbus/mcp/notifications.py`:
  - **SSE push:** When NATS message arrives on subscribed subject, push MCP notification over GET SSE stream
  - **Piggyback:** Every tool response includes `_pending` field with count and preview of buffered messages
  - **Poll:** `bus_check()` drains the per-session buffer

**Dependencies:** Tasks 2.1, 2.2

**Complexity:** M

**Acceptance Criteria:**
- SSE stream delivers notifications within 1 second of NATS message
- Tool responses include accurate `_pending` counts
- `bus_check()` returns messages and clears buffer (no repeats)

#### Task 2.4: Claude Code Integration

**Deliverable:** Configuration and documentation for connecting Claude Code.

**Files:**
- `docs/claude-code-setup.md` — Step-by-step setup guide
- Example `.claude/settings.json` entry:
  ```json
  {
    "mcpServers": {
      "agentbus": {
        "type": "streamableHttp",
        "url": "https://agentbus.example.com/mcp",
        "headers": {
          "Authorization": "Bearer ${AGENTBUS_TOKEN}"
        }
      }
    }
  }
  ```
- `tests/e2e/test_claude_code_integration.py` — Automated test simulating Claude Code MCP client

**Dependencies:** Tasks 2.1–2.3

**Complexity:** S

**Acceptance Criteria:**
- Claude Code connects to AgentBus with one settings.json entry
- All 7 tools appear in Claude Code's tool list
- Agent can send and receive messages during a session

#### Task 2.5: Copilot CLI Integration

**Deliverable:** Configuration for connecting Copilot CLI.

**Files:**
- `docs/copilot-cli-setup.md` — Setup guide
- Example `~/.copilot/mcp-config.json` entry
- Validation that Copilot CLI discovers and uses bus tools

**Dependencies:** Tasks 2.1–2.3

**Complexity:** S

**Acceptance Criteria:**
- Copilot CLI connects via MCP
- Tools are discoverable and usable from Copilot CLI session

---

### Phase 3: Multi-Tenancy

Enforce hierarchical data isolation so each org/team/user sees only their authorized channels.

#### Task 3.1: JWT Claims-Based Authorization

**Deliverable:** Pub/sub authorization based on JWT org/team/user claims.

**Files:**
- `src/agentbus/tenancy/resolver.py`:
  - `resolve_subject(jwt_claims, channel, scope)` — Maps `(org, team, user, channel, scope)` → NATS subject string
  - `authorize_subscribe(jwt_claims, pattern)` — Validates the pattern is within the user's scope
  - `authorize_publish(jwt_claims, subject)` — Validates the user can publish to the subject
- Update `src/agentbus/api/rest.py`, `websocket.py`, `mcp/tools.py` to call authorization checks

**Dependencies:** Phase 2 complete

**Complexity:** M

**Acceptance Criteria:**
- User with `org=acme, team=platform` can subscribe to `acme.platform.*` but not `other-org.*`
- `scope=team` publishes to `acme.platform.shared.{channel}`
- `scope=user` publishes to `acme.platform.chuck.{channel}`
- Unauthorized pub/sub returns 403

#### Task 3.2: NATS Account Isolation

**Deliverable:** Per-org NATS accounts for defense-in-depth isolation.

**Files:**
- `src/agentbus/tenancy/accounts.py`:
  - `ensure_account(org)` — Create NATS account for org if not exists
  - `get_account_credentials(org)` — Return NKey credentials for the org's account
- `deploy/nats.conf` — Update to enable multi-account mode with operator/account/user hierarchy
- API server connects to NATS with per-org credentials based on incoming JWT

**Dependencies:** Task 3.1

**Complexity:** L

**Acceptance Criteria:**
- Messages from org A are impossible to see from org B at the NATS level
- API server correctly routes to per-org NATS accounts
- New org creation provisions a NATS account automatically

#### Task 3.3: Admin API

**Deliverable:** Management endpoints for orgs, teams, users, and API keys.

**Files:**
- `src/agentbus/tenancy/admin.py`:
  - `POST /admin/orgs` — Create org, generate org API key
  - `GET /admin/orgs/{org}/teams` — List teams
  - `POST /admin/orgs/{org}/teams` — Create team
  - `POST /admin/orgs/{org}/teams/{team}/users` — Create user, generate user API key
  - `DELETE /admin/orgs/{org}/teams/{team}/users/{user}` — Remove user
  - `POST /admin/orgs/{org}/api-keys` — Generate new API key
  - `DELETE /admin/orgs/{org}/api-keys/{key_id}` — Revoke API key
- Storage: Start with JSON file or SQLite for admin state (orgs, teams, users, keys). Not message content — this is metadata only.

**Dependencies:** Tasks 3.1, 3.2

**Complexity:** M

**Acceptance Criteria:**
- Full CRUD for orgs, teams, users
- Generated API keys can be exchanged for properly-scoped JWTs
- Revoking an API key invalidates future token exchanges
- Admin endpoints require admin-scoped JWT

---

### Phase 4: Developer Experience

Make it easy for anyone to build on AgentBus.

#### Task 4.1: Python SDK

**Deliverable:** Pip-installable Python client library.

**Files:**
- `src/sdk/python/agentbus_client/`:
  - `client.py` — `AgentBusClient(url, api_key)` with methods: `send()`, `subscribe()`, `poll()`, `who()`, `ask()`, `answer()`
  - `models.py` — Re-export message models
  - `websocket.py` — WebSocket subscription with async iterator
  - `auth.py` — Automatic token refresh
- `src/sdk/python/pyproject.toml`
- `src/sdk/python/README.md`

**Dependencies:** Phase 1 complete

**Complexity:** M

**Acceptance Criteria:**
- `pip install agentbus-client` works
- 5-line quickstart: connect, subscribe, send, receive
- Handles auth token refresh transparently
- Async and sync interfaces

#### Task 4.2: TypeScript SDK

**Deliverable:** npm-installable TypeScript client library.

**Files:**
- `src/sdk/typescript/agentbus-client/`:
  - `src/client.ts` — `AgentBusClient` class
  - `src/models.ts` — Message types
  - `src/websocket.ts` — WebSocket subscription
  - `src/auth.ts` — Token management
- `src/sdk/typescript/package.json`
- `src/sdk/typescript/tsconfig.json`

**Dependencies:** Phase 1 complete

**Complexity:** M

**Acceptance Criteria:**
- `npm install agentbus-client` works
- TypeScript types for all message schemas
- Works in Node.js and browser environments
- WebSocket auto-reconnect

#### Task 4.3: Web Dashboard

**Deliverable:** Browser-based UI for monitoring channels and messages.

**Files:**
- `src/dashboard/` — React or vanilla JS SPA:
  - Channel list with subscriber counts
  - Real-time message stream viewer (WebSocket)
  - Connected agents list (`/who`)
  - Auth: login with API key
  - Deploy as static files served by FastAPI

**Dependencies:** Phase 1 complete

**Complexity:** L

**Acceptance Criteria:**
- Shows real-time message flow across channels
- Displays connected agents
- Can send test messages from the UI
- Authenticated — only shows channels within user's scope

#### Task 4.4: Documentation & Quickstart

**Deliverable:** Comprehensive docs for all integration paths.

**Files:**
- `docs/quickstart.md` — 5-minute getting started
- `docs/api-reference.md` — Full REST + WebSocket API docs (or auto-generated OpenAPI)
- `docs/mcp-integration.md` — MCP setup for Claude Code, Copilot CLI
- `docs/architecture.md` — System design overview
- `docs/deployment.md` — Azure deployment guide
- `docs/examples/` — Integration examples:
  - `examples/claude-code-pair-programming.md`
  - `examples/cross-team-research.md`
  - `examples/ci-notifications.md`

**Dependencies:** Phases 1–3

**Complexity:** M

**Acceptance Criteria:**
- A new user can go from zero to sending messages in 5 minutes
- All API endpoints documented with examples
- Each client type has a working integration example

---

### Phase Dependencies

```
Phase 1 (Core Relay)
  └── Phase 2 (MCP Integration)
        └── Phase 3 (Multi-Tenancy)
              └── Phase 4 (Developer Experience)

Phase 4 Tasks 4.1, 4.2, 4.3 can start after Phase 1.
Phase 4 Task 4.4 requires Phases 1-3.
```

### Estimated Timeline

| Phase | Tasks | Complexity | Estimate |
|-------|-------|------------|----------|
| Phase 1 | 7 tasks | 2S + 3M + 2S = mixed | 3-4 days |
| Phase 2 | 5 tasks | 3M + 2S | 2-3 days |
| Phase 3 | 3 tasks | 1L + 2M | 2-3 days |
| Phase 4 | 4 tasks | 2M + 1L + 1M | 3-4 days |
| **Total** | **19 tasks** | | **10-14 days** |
