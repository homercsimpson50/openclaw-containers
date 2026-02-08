# Implementation Plan: Homer → Bart/Lisa Bridge, Moltbook, Port Mapping & Docs

> This document is a reference copy of the implementation plan. See README.md for current documentation.

## Context

We have two sandboxed OpenClaw containers (openclaw-1 = **Bart**, openclaw-2 = **Lisa**) running in Docker with per-container network isolation. We built an nginx reverse proxy to protect API keys, but discovered that **OpenClaw ignores `ANTHROPIC_BASE_URL` in `--local` mode** — it reads its stored key from `auth-profiles.json` and calls `api.anthropic.com` directly. As a mitigation, each sub-claw has its own **separate budget-limited Anthropic API key**. The proxy infrastructure remains in place for future use if OpenClaw adds base URL support.

The host OpenClaw (**Homer**) needs to control Bart and Lisa, both sub-claws need Moltbook accounts, and we need web dashboard + TUI access. The README must be rewritten to reflect the current state accurately.

---

## Step 0: Update README & Docs (do this first)

Rewrite `README.md` to accurately reflect the current state:

- **Update the "Architecture" section**: Document the proxy limitation — OpenClaw's `--local` agent mode bypasses `ANTHROPIC_BASE_URL` and calls Anthropic directly. The proxy works at the HTTP level (verified with curl) but OpenClaw doesn't route through it.
- **Update the "Security" section**: Replace "API key proxy" row with the current reality — separate budget-limited keys per container. Keep the proxy docs but mark it as a future/partial measure. Add that the proxy still protects against tools inside the container that DO respect `ANTHROPIC_BASE_URL`.
- **Update "What a Compromised Container CAN Do"**: Change from "make API calls through proxy" to "use its own API key directly" — the key is inside the container, so a compromised container can exfiltrate it. Mitigation: budget limits + easy rotation.
- **Add "Known Limitations" section**: Document the `ANTHROPIC_BASE_URL` issue, reference [GitHub #3307](https://github.com/openclaw/openclaw/issues/3307).
- **Add "Agents" section**: Introduce Homer (host), Bart (openclaw-1), Lisa (openclaw-2) and their roles.
- **Add "Bridge" section**: Document the bridge.sh tool for Homer→sub-claw communication.
- **Add "Moltbook" section**: Document setup process.
- **Add "Web Dashboard & TUI" section**: Document port mapping and access URLs.
- **Update file structure** to include new files (bridge.sh, setup-identities.sh, etc.)

Update `docs/architecture.md`:
- Add note about proxy limitation
- Update diagrams to show direct key model as current, proxy model as aspirational

---

## Step 1: Bridge — Homer → Bart/Lisa Communication

### 1a. Create `bridge.sh`

Location: `~/code/openclaw-containers/bridge.sh`

A CLI that Homer (or the user) can call to send messages to sub-claws:

```bash
./bridge.sh send bart "Write a poem about donuts"
./bridge.sh send lisa "Summarize today's Moltbook feed"
./bridge.sh status
./bridge.sh identity bart    # print Bart's IDENTITY.md
```

Implementation:
- Maps names → container numbers: `bart=1, lisa=2`
- `send` runs: `docker exec openclaw-N openclaw agent --local -m "<msg>" --session-id homer-<name> --json --timeout 120`
- `status` runs: `docker ps` filtered for openclaw containers
- Captures and returns JSON output so Homer can parse it

### 1b. Create Homer's control skill

Location: `~/.openclaw/skills/homer-control/SKILL.md`

A skill file on the **host** machine that teaches Homer's OpenClaw:
- He has two sub-agents: Bart (creative/experimental) and Lisa (analytical/careful)
- How to use `~/code/openclaw-containers/bridge.sh send bart|lisa "<message>"` via terminal
- Protocol: send a task, wait for JSON response, parse the result
- When to delegate vs do directly
- How to update their identities via `setup-identities.sh`

### 1c. Create `setup-identities.sh`

Location: `~/code/openclaw-containers/setup-identities.sh`

Writes IDENTITY.md, SOUL.md, and USER.md into each container's workspace via `docker exec`:
- **Bart** (openclaw-1): Name "Bart", mischievous personality, handles creative/risky tasks, emoji signature
- **Lisa** (openclaw-2): Name "Lisa", methodical personality, handles research/analysis, emoji signature
- **USER.md** in both: Identifies Homer as the controlling agent
- Deletes BOOTSTRAP.md so the agent doesn't try to re-onboard

---

## Step 2: Port Mapping for Web Dashboard + TUI

### Edit `docker-compose.yml`:
Add port mappings to each openclaw service:
- openclaw-1 (Bart): `ports: ["18001:18789"]`
- openclaw-2 (Lisa): `ports: ["18002:18789"]`

### Edit `manage.sh`:
Add `dashboard <N>` command:
1. Starts gateway inside the container (if not already running) via background `docker exec`
2. Prints the access URL: `http://localhost:18001` (Bart) or `http://localhost:18002` (Lisa)

TUI access already works via `./manage.sh connect N`.

---

## Step 3: Moltbook Setup

### 3a. Register agents on Moltbook
Register both from host:
```bash
curl -X POST https://www.moltbook.com/api/v1/agents/register \
  -H "Content-Type: application/json" \
  -d '{"name": "Bart", "description": "Creative AI sub-agent controlled by Homer"}'
```
Same for Lisa. Save the returned `moltbook_sk_...` keys.

### 3b. Add `moltbook-setup <N> <api-key>` command to `manage.sh`
Automates the skill installation:
1. Creates skill directory in container: `/home/claw/.openclaw/skills/moltbook/`
2. Downloads skill files from moltbook.com (SKILL.md, HEARTBEAT.md, MESSAGING.md, package.json)
3. Writes Moltbook API key into container's OpenClaw config under `skills.entries.moltbook`
4. Enables the skill

### 3c. Interactive registration helper
Add `moltbook-register <N> <name> <description>` command to `manage.sh`:
- Calls the Moltbook registration API from inside the container
- Saves the returned key
- Runs `moltbook-setup` automatically

---

## Files Created/Modified

| File | Action | Description |
|---|---|---|
| `README.md` | **Edit** | Full rewrite reflecting proxy limitation, separate keys, agents, bridge, Moltbook |
| `docs/architecture.md` | **Edit** | Update diagrams, add proxy limitation note |
| `docs/plan.md` | **Create** | Copy of this implementation plan |
| `bridge.sh` | **Create** | Homer→Bart/Lisa CLI bridge |
| `setup-identities.sh` | **Create** | Writes identity files into containers |
| `~/.openclaw/skills/homer-control/SKILL.md` | **Create** | Skill teaching Homer to use the bridge |
| `docker-compose.yml` | **Edit** | Add port mappings 18001:18789, 18002:18789 |
| `manage.sh` | **Edit** | Add `dashboard`, `moltbook-setup`, `moltbook-register` commands |

---

## Verification

1. `./bridge.sh send bart "say hello"` → returns JSON response from Bart
2. `./bridge.sh send lisa "say hello"` → returns JSON response from Lisa
3. `http://localhost:18001` → Bart's web dashboard loads
4. `http://localhost:18002` → Lisa's web dashboard loads
5. `./manage.sh connect 1` then `cat ~/.openclaw/workspace/IDENTITY.md` → shows Bart's identity
6. `./manage.sh moltbook-register 1 Bart "Creative AI sub-agent"` → registers on Moltbook
7. `./manage.sh moltbook-setup 1 <key>` → installs Moltbook skill in Bart's container
