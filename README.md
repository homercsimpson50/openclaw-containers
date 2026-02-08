# openclaw-containers

Sandboxed [OpenClaw](https://github.com/openclaw/openclaw) instances running in Docker with network isolation and API key protection via a reverse proxy.

## Why

OpenClaw is a powerful agentic AI assistant that can execute commands, browse the web, and interact with messaging platforms. When connecting it to external services (Moltbook, WhatsApp, Telegram, etc.), a compromised instance could exfiltrate API keys, attack other instances, or pivot to your host.

This setup isolates each OpenClaw instance in its own container and network, with a reverse proxy that keeps your real API keys out of reach.

## Architecture

See [docs/architecture.md](docs/architecture.md) for detailed diagrams of the proxy flow and network topology.

**TL;DR:**

```
openclaw-1 ──(dummy key)──► api-proxy ──(real key)──► api.anthropic.com
openclaw-2 ──(dummy key)──► api-proxy ──(real key)──► api.openai.com
openclaw-1 ──✗──► openclaw-2   (different networks, can't communicate)
```

## Quick Start

```bash
# 1. Clone and enter the directory
cd ~/code/openclaw-containers

# 2. Set your API key(s) — only the proxy ever sees these
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...          # optional

# 3. Build images
./manage.sh build

# 4. Start everything (proxy + 2 openclaw containers)
./manage.sh up

# 5. Run the onboarding wizard in each container
./manage.sh onboard 1
./manage.sh onboard 2

# 6. Start using OpenClaw
./manage.sh run 1                     # interactive agent
./manage.sh run 1 "summarize my inbox"  # one-shot
./manage.sh gateway 1                 # start messaging gateway
./manage.sh connect 1                 # bash shell
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
| `./manage.sh add <N>` | Spin up a new openclaw-N container |
| `./manage.sh rm <N>` | Remove openclaw-N (shared files kept) |
| `./manage.sh logs <N>` | Tail logs for openclaw-N |
| `./manage.sh exec <N> <cmd>` | Run a command in openclaw-N |
| `./manage.sh proxy-logs` | Tail API proxy logs |

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

**`proxy/Dockerfile`** — The API proxy:
- Stock `nginx:alpine` image with a single config template
- Template uses nginx's built-in `envsubst` to inject API keys at startup
- Runs with `read_only: true` filesystem (tmpfs for nginx's cache/pid/tmp)
- Only 256MB memory, 0.5 CPU — it just forwards HTTP requests

### Docker Compose Orchestration

`docker-compose.yml` defines three services:

| Service | Image | Networks | Has Real API Keys |
|---|---|---|---|
| `api-proxy` | `nginx:alpine` | net-oc1, net-oc2 | Yes |
| `openclaw-1` | `openclaw-sandbox` | net-oc1 | No (dummy) |
| `openclaw-2` | `openclaw-sandbox` | net-oc2 | No (dummy) |

Each OpenClaw container lives on its own bridge network. The proxy connects to all networks, acting as the sole bridge for API traffic. Containers on different networks cannot discover or reach each other.

## Security

### Hardening Applied

| Measure | What It Does |
|---|---|
| **API key proxy** | Real keys only exist in the proxy container. OpenClaw containers get `ANTHROPIC_API_KEY=proxy` (dummy) and route through the proxy via `ANTHROPIC_BASE_URL`. |
| **Per-container networks** | Each container gets its own Docker bridge network. No inter-container communication is possible. |
| **`cap_drop: ALL`** | All Linux capabilities stripped. No raw sockets, no packet crafting, no mount, no chown, nothing. |
| **`no-new-privileges`** | Prevents suid/sgid escalation inside the container. |
| **Non-root user** | OpenClaw runs as `claw` (UID 1000), not root. |
| **Resource limits** | 2 CPUs + 4GB RAM per container. Prevents resource exhaustion attacks on the host. |
| **Read-only proxy** | The proxy container has a read-only root filesystem. |
| **No published ports** | No container ports are mapped to the host. Nothing is reachable from outside. |
| **No Docker socket** | The Docker socket is never mounted. Containers cannot control Docker. |
| **Scoped volume mounts** | Each container only sees its own `shared/openclaw-N/` directory. No access to host home, system files, or other containers' data. |

### What a Compromised Container CAN Do

These are inherent to the use case and cannot be fully mitigated without breaking functionality:

- **Make API calls through the proxy** — The container can call the Anthropic/OpenAI APIs via the proxy (that's its purpose). This could run up your bill. Monitor with `./manage.sh proxy-logs`.
- **Access the internet** — OpenClaw needs internet for messaging platforms, web browsing, and API calls. A compromised container could exfiltrate data from `/workspace` or establish outbound connections.
- **Write to its shared directory** — The `shared/openclaw-N/` mount is read-write. A compromised container could place malicious files there. Don't blindly execute files from this directory on your host.
- **Use CPU/RAM up to limits** — A container could mine crypto or do other compute-intensive tasks within its 2 CPU / 4GB limit.

### What a Compromised Container CANNOT Do

- **Read your real API keys** — Keys are only in the proxy, which is a separate container/namespace.
- **Reach other OpenClaw containers** — Separate networks; no route exists.
- **Escalate to root** — `no-new-privileges` + non-root user + all capabilities dropped.
- **Access host filesystem** — Only the scoped `/workspace` mount is available.
- **Control Docker** — No socket mounted; no capabilities to interact with the daemon.
- **Sniff or spoof network traffic** — `NET_RAW` capability is not granted; ARP spoofing is impossible.
- **Redirect API keys to attacker servers** — The proxy hardcodes upstream hosts (`api.anthropic.com`, `api.openai.com`) in the nginx config. The container has no way to change where the proxy sends the key.

### Remaining Risks

- **Shared proxy** — If the proxy container itself is compromised (unlikely — it's a minimal nginx with no inbound internet exposure), the attacker gets all API keys. The proxy's attack surface is very small: it only accepts HTTP on an internal port from the OpenClaw containers.
- **Docker Desktop VM escape** — A kernel-level container escape in Docker Desktop's Linux VM would compromise the host. This is a Docker/OS-level risk, not specific to this setup.
- **Supply chain** — The `openclaw@latest` npm package is pulled at build time. If the package is compromised upstream, the container image will contain malicious code. Pin to a specific version in production.

## File Structure

```
openclaw-containers/
├── Dockerfile.openclaw       # OpenClaw sandbox image
├── docker-compose.yml        # Orchestration (proxy + 2 containers)
├── manage.sh                 # Management CLI
├── proxy/
│   ├── Dockerfile            # nginx proxy image
│   └── default.conf.template # nginx config (envsubst for API keys)
├── shared/
│   ├── openclaw-1/           # Host-mounted workspace for container 1
│   └── openclaw-2/           # Host-mounted workspace for container 2
├── docs/
│   └── architecture.md       # Proxy & network diagrams
├── .env.example              # Template for API keys
├── .gitignore                # Ignores .env and shared/
└── README.md                 # This file
```

## License

MIT
