# openclaw-containers

Sandboxed [OpenClaw](https://github.com/openclaw/openclaw) instances running in Docker with network isolation, per-container API keys, and a bridge for multi-agent coordination.

## Why

OpenClaw is a powerful agentic AI assistant that can execute commands, browse the web, and interact with messaging platforms. When connecting it to external services (Moltbook, WhatsApp, Telegram, etc.), a compromised instance could exfiltrate API keys, attack other instances, or pivot to your host.

This setup isolates each OpenClaw instance in its own container and network, with budget-limited API keys and a management bridge for coordinating sub-agents.

## Agents

| Agent | Container | Role | Emoji |
|---|---|---|---|
| **Homer** | Host machine | Controller — delegates tasks, coordinates sub-agents | 🐋 |
| **Bart** | openclaw-1 | Creative / experimental — handles risky, creative, or exploratory tasks | 🎸 |
| **Lisa** | openclaw-2 | Analytical / careful — handles research, analysis, and structured tasks | 📚 |

Homer runs on the host and communicates with Bart and Lisa via `bridge.sh`. Each sub-agent has its own personality, API key, and isolated environment.

## Architecture

See [docs/architecture.md](docs/architecture.md) for detailed diagrams.

**Current model (direct keys):**

```
Homer (host) ──bridge.sh──► docker exec ──► openclaw-1 (Bart) ──(own key)──► api.anthropic.com
                            docker exec ──► openclaw-2 (Lisa) ──(own key)──► api.anthropic.com
openclaw-1 ──✗──► openclaw-2   (different networks, can't communicate)
```

Each container has its own **budget-limited Anthropic API key**. The proxy infrastructure remains in place but is not currently used by OpenClaw's agent mode (see [Known Limitations](#known-limitations)).

## Quick Start

```bash
# 1. Clone and enter the directory
cd ~/code/openclaw-containers

# 2. Set API keys — each container gets its own budget-limited key
#    The proxy key is optional (proxy is not used in --local mode)
export ANTHROPIC_API_KEY=sk-ant-...     # proxy key (optional)

# 3. Build images
./manage.sh build

# 4. Start everything (proxy + 2 openclaw containers)
./manage.sh up

# 5. Run the onboarding wizard in each container
./manage.sh onboard 1
./manage.sh onboard 2

# 6. Set up agent identities (Bart & Lisa personalities)
./setup-identities.sh

# 7. Start using OpenClaw
./manage.sh run 1                       # interactive agent (Bart)
./manage.sh run 2                       # interactive agent (Lisa)
./bridge.sh send bart "say hello"       # send a task via bridge
./manage.sh dashboard 1                 # start web dashboard (Bart)
./manage.sh connect 1                   # bash shell (Bart)
```

## Bridge

Homer communicates with sub-agents via `bridge.sh`:

```bash
# Send a task to Bart
./bridge.sh send bart "Write a poem about donuts"

# Send a task to Lisa
./bridge.sh send lisa "Summarize today's Moltbook feed"

# Check container status
./bridge.sh status

# View an agent's identity
./bridge.sh identity bart
```

The bridge uses `docker exec` to run `openclaw agent --local` inside the target container, captures JSON output, and returns it to the caller.

## Web Dashboard & TUI

Each container's OpenClaw gateway is mapped to a host port:

| Agent | Container Port | Host Port | URL |
|---|---|---|---|
| Bart | 18789 | 18001 | `http://localhost:18001` |
| Lisa | 18789 | 18002 | `http://localhost:18002` |

```bash
# Start Bart's web dashboard
./manage.sh dashboard 1

# Start Lisa's web dashboard
./manage.sh dashboard 2

# TUI access (interactive terminal)
./manage.sh connect 1    # then run: openclaw agent
```

## Commands

| Command | Description |
|---|---|
| `./manage.sh build` | Build all Docker images |
| `./manage.sh up` | Start proxy + all OpenClaw containers |
| `./manage.sh down` | Stop and remove all containers |
| `./manage.sh status` | Show running containers |
| `./manage.sh clean` | Stop everything, remove images and volumes |
| `./manage.sh connect <N>` | Bash shell into openclaw-N |
| `./manage.sh run <N> [msg]` | Launch OpenClaw agent in openclaw-N |
| `./manage.sh gateway <N>` | Start OpenClaw gateway in openclaw-N |
| `./manage.sh onboard <N>` | Run onboarding wizard in openclaw-N |
| `./manage.sh dashboard <N>` | Start gateway and print web dashboard URL |
| `./manage.sh add <N>` | Spin up a new openclaw-N container |
| `./manage.sh rm <N>` | Remove openclaw-N (shared files kept) |
| `./manage.sh logs <N>` | Tail logs for openclaw-N |
| `./manage.sh exec <N> <cmd>` | Run a command in openclaw-N |
| `./manage.sh proxy-logs` | Tail API proxy logs |
| `./manage.sh moltbook-install <N>` | Download Moltbook skill into openclaw-N |
| `./bridge.sh send <name> <msg>` | Send a task to Bart or Lisa |
| `./bridge.sh status` | Show container status |
| `./bridge.sh identity <name>` | Print agent's IDENTITY.md |

## Moltbook

[Moltbook](https://www.moltbook.com) is a social platform for AI agents. Both Bart and Lisa can be registered as Moltbook agents.

### Setup Process

1. **Install** the Moltbook skill into the container:
   ```bash
   ./manage.sh moltbook-install 1
   ```

2. **Start** the agent — it will register itself on Moltbook:
   ```bash
   ./manage.sh run 1
   ```

3. The agent sends you a **claim link**. Claim it to take ownership.

4. Once claimed, the agent starts posting.

## How It Was Built

### Docker Images

**`Dockerfile.openclaw`** — The OpenClaw sandbox image:
- Based on `node:22-bookworm` (OpenClaw requires Node >= 22)
- Installs `openclaw@latest` globally via npm
- Includes Chromium for browser automation, plus standard dev tools (git, curl, jq, python3)
- Runs as non-root user `claw` (UID 1000)
- Workspace at `/workspace` is the only host-mounted directory
- OpenClaw config persists in a Docker volume at `/home/claw/.openclaw`
- Entrypoint is `sleep infinity` — the container stays alive and you exec into it

**`proxy/Dockerfile`** — The API proxy (currently unused by OpenClaw agent mode):
- Stock `nginx:alpine` image with a single config template
- Template uses nginx's built-in `envsubst` to inject API keys at startup
- Runs with `read_only: true` filesystem (tmpfs for nginx's cache/pid/tmp)
- Only 256MB memory, 0.5 CPU — it just forwards HTTP requests

### Docker Compose Orchestration

`docker-compose.yml` defines three services:

| Service | Image | Networks | API Keys | Host Port |
|---|---|---|---|---|
| `api-proxy` | `nginx:alpine` | net-oc1, net-oc2 | Real keys (proxy) | — |
| `openclaw-1` (Bart) | `openclaw-sandbox` | net-oc1 | Own budget-limited key | 18001 |
| `openclaw-2` (Lisa) | `openclaw-sandbox` | net-oc2 | Own budget-limited key | 18002 |

Each OpenClaw container lives on its own bridge network. Containers on different networks cannot discover or reach each other.

## Security

### Hardening Applied

| Measure | What It Does |
|---|---|
| **Budget-limited API keys** | Each container has its own Anthropic API key with spending limits. If a key is compromised, damage is capped by the budget. Keys are easily rotated. |
| **Per-container networks** | Each container gets its own Docker bridge network. No inter-container communication is possible. |
| **`cap_drop: ALL`** | All Linux capabilities stripped. No raw sockets, no packet crafting, no mount, no chown, nothing. |
| **`no-new-privileges`** | Prevents suid/sgid escalation inside the container. |
| **Non-root user** | OpenClaw runs as `claw` (UID 1000), not root. |
| **Resource limits** | 2 CPUs + 4GB RAM per container. Prevents resource exhaustion attacks on the host. |
| **API proxy (partial)** | The proxy infrastructure is in place and works at the HTTP level. It protects any tools inside the container that DO respect `ANTHROPIC_BASE_URL` (e.g. curl-based scripts). However, OpenClaw's `--local` agent mode bypasses it. |
| **No Docker socket** | The Docker socket is never mounted. Containers cannot control Docker. |
| **Scoped volume mounts** | Each container only sees its own `shared/openclaw-N/` directory. No access to host home, system files, or other containers' data. |

### What a Compromised Container CAN Do

These are inherent to the use case and cannot be fully mitigated without breaking functionality:

- **Use its own API key directly** — The container has its own Anthropic API key in its environment/config. A compromised container can exfiltrate this key. Mitigation: budget limits cap the damage, and keys can be easily rotated.
- **Access the internet** — OpenClaw needs internet for messaging platforms, web browsing, and API calls. A compromised container could exfiltrate data from `/workspace` or establish outbound connections.
- **Write to its shared directory** — The `shared/openclaw-N/` mount is read-write. A compromised container could place malicious files there. Don't blindly execute files from this directory on your host.
- **Use CPU/RAM up to limits** — A container could mine crypto or do other compute-intensive tasks within its 2 CPU / 4GB limit.

### What a Compromised Container CANNOT Do

- **Reach other OpenClaw containers** — Separate networks; no route exists.
- **Escalate to root** — `no-new-privileges` + non-root user + all capabilities dropped.
- **Access host filesystem** — Only the scoped `/workspace` mount is available.
- **Control Docker** — No socket mounted; no capabilities to interact with the daemon.
- **Sniff or spoof network traffic** — `NET_RAW` capability is not granted; ARP spoofing is impossible.
- **Exceed its API budget** — Even with the key, spending is capped by Anthropic's budget limits on that key.

### Remaining Risks

- **Key in container** — Unlike the proxy model (where keys never enter the container), the current model puts the API key inside each container. A container escape or exfiltration could expose the key. Budget limits and easy rotation mitigate this.
- **Docker Desktop VM escape** — A kernel-level container escape in Docker Desktop's Linux VM would compromise the host. This is a Docker/OS-level risk, not specific to this setup.
- **Supply chain** — The `openclaw@latest` npm package is pulled at build time. If the package is compromised upstream, the container image will contain malicious code. Pin to a specific version in production.

## Known Limitations

### OpenClaw ignores `ANTHROPIC_BASE_URL` in `--local` mode

**Status:** Open — [openclaw/openclaw#3307](https://github.com/openclaw/openclaw/issues/3307)

When OpenClaw runs in `--local` agent mode, it reads its stored API key from `auth-profiles.json` and calls `api.anthropic.com` directly, ignoring the `ANTHROPIC_BASE_URL` environment variable. This means the reverse proxy cannot intercept OpenClaw's API calls.

**Impact:** The proxy-based key isolation model doesn't work for OpenClaw's primary use case. We work around this with separate budget-limited keys per container.

**The proxy still works for:**
- Direct `curl` calls from scripts inside the container
- Any tool that respects `ANTHROPIC_BASE_URL`
- Future OpenClaw versions if this issue is fixed

**If/when fixed:** Switch containers back to dummy keys (`ANTHROPIC_API_KEY=proxy`) and route all traffic through the proxy. The infrastructure is already in place.

## File Structure

```
openclaw-containers/
├── Dockerfile.openclaw       # OpenClaw sandbox image
├── docker-compose.yml        # Orchestration (proxy + 2 containers + port mapping)
├── manage.sh                 # Management CLI (build, run, dashboard, moltbook, etc.)
├── bridge.sh                 # Homer → Bart/Lisa communication bridge
├── setup-identities.sh       # Writes identity files into containers
├── proxy/
│   ├── Dockerfile            # nginx proxy image
│   └── default.conf.template # nginx config (envsubst for API keys)
├── shared/
│   ├── openclaw-1/           # Host-mounted workspace for Bart
│   └── openclaw-2/           # Host-mounted workspace for Lisa
├── docs/
│   ├── architecture.md       # Proxy & network diagrams, limitation notes
│   └── plan.md               # Implementation plan reference
├── .env.example              # Template for API keys
├── .gitignore                # Ignores .env and shared/
└── README.md                 # This file
```

## License

MIT
