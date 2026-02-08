#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Name → container number mapping ──────────────────────────────
resolve_name() {
    local name
    name=$(echo "$1" | tr '[:upper:]' '[:lower:]')  # portable lowercase
    case "$name" in
        bart) echo 1 ;;
        lisa) echo 2 ;;
        [0-9]*) echo "$name" ;;
        *) echo "Unknown agent: $name" >&2; echo "Known agents: bart (openclaw-1), lisa (openclaw-2)" >&2; exit 1 ;;
    esac
}

# ── Usage ─────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
Usage: ./bridge.sh <command> [args]

Homer → Sub-claw communication bridge.

Commands:
  send <name> <message>    Send a task to an agent and get JSON response
  status                   Show status of all openclaw containers
  identity <name>          Print an agent's IDENTITY.md

Agents:
  bart    openclaw-1    Creative / experimental
  lisa    openclaw-2    Analytical / careful

Examples:
  ./bridge.sh send bart "Write a poem about donuts"
  ./bridge.sh send lisa "Summarize today's Moltbook feed"
  ./bridge.sh status
  ./bridge.sh identity bart
USAGE
}

# ── Commands ──────────────────────────────────────────────────────

cmd_send() {
    local name="${1:?Usage: ./bridge.sh send <name> <message>}"
    shift
    local msg="${*:?Usage: ./bridge.sh send <name> <message>}"
    local n
    n=$(resolve_name "$name")
    local container="openclaw-${n}"
    local session_id="homer-$(echo "$name" | tr '[:upper:]' '[:lower:]')"

    # Verify container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "Error: ${container} is not running." >&2
        echo "Start it with: cd ${SCRIPT_DIR} && ./manage.sh up" >&2
        exit 1
    fi

    echo "Sending task to ${name} (${container})..." >&2
    docker exec "$container" \
        openclaw agent \
        --local \
        -m "$msg" \
        --session-id "$session_id" \
        --json \
        --timeout 120
}

cmd_status() {
    echo "OpenClaw container status:"
    docker ps \
        --filter "name=openclaw-" \
        --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
}

cmd_identity() {
    local name="${1:?Usage: ./bridge.sh identity <name>}"
    local n
    n=$(resolve_name "$name")
    local container="openclaw-${n}"

    # Verify container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "Error: ${container} is not running." >&2
        exit 1
    fi

    docker exec "$container" cat /home/claw/.openclaw/workspace/IDENTITY.md 2>/dev/null || \
        echo "No IDENTITY.md found in ${container}. Run ./setup-identities.sh first."
}

# ── Dispatch ──────────────────────────────────────────────────────

case "${1:-}" in
    send)     shift; cmd_send "$@" ;;
    status)   cmd_status ;;
    identity) cmd_identity "${2:-}" ;;
    *)        usage ;;
esac
