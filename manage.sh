#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE="docker compose"

usage() {
    cat <<'USAGE'
Usage: ./manage.sh <command> [args]

General:
  build                 Build all images
  up                    Start all containers (proxy + openclaw)
  down                  Stop and remove all containers
  status                Show all container status
  clean                 Stop all containers, remove images and volumes

OpenClaw containers:
  connect <N>           Open bash shell in openclaw-N
  run <N> [msg]         Launch OpenClaw agent in openclaw-N
  gateway <N>           Start OpenClaw gateway in openclaw-N
  onboard <N>           Run OpenClaw onboarding wizard in openclaw-N
  add <N>               Add a new openclaw-N container
  rm <N>                Remove openclaw-N container
  logs <N>              Tail logs for openclaw-N
  exec <N> <cmd>        Run command in openclaw-N

Proxy:
  proxy-logs            Tail API proxy logs
USAGE
}

check_api_key() {
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo "Warning: ANTHROPIC_API_KEY is not set."
        echo "The API proxy needs it. Export before running:"
        echo "  export ANTHROPIC_API_KEY=sk-ant-..."
        echo ""
    fi
}

# ── Build / lifecycle ─────────────────────────────────────────────

cmd_build() {
    echo "Building images..."
    $COMPOSE build
}

cmd_up() {
    check_api_key
    for dir in shared/openclaw-{1,2}; do
        mkdir -p "$dir"
    done
    echo "Starting all containers..."
    $COMPOSE up -d
    echo ""
    cmd_status
}

cmd_down() {
    echo "Stopping all containers..."
    $COMPOSE down
}

cmd_status() {
    echo "Container status:"
    docker ps \
        --filter "name=openclaw-" \
        --filter "name=api-proxy" \
        --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
}

cmd_clean() {
    echo "Stopping all containers, removing images and volumes..."
    $COMPOSE down --rmi local --volumes
    echo "Done."
}

# ── OpenClaw containers ──────────────────────────────────────────

cmd_connect() {
    local n="${1:?Usage: ./manage.sh connect <N>}"
    echo "Connecting to openclaw-${n}..."
    docker exec -it "openclaw-${n}" bash
}

cmd_run() {
    local n="${1:?Usage: ./manage.sh run <N> [message]}"
    shift
    local msg="${*:-}"
    echo "Launching OpenClaw agent in openclaw-${n}..."
    if [ -n "$msg" ]; then
        docker exec -it "openclaw-${n}" openclaw agent --message "$msg"
    else
        docker exec -it "openclaw-${n}" openclaw agent
    fi
}

cmd_gateway() {
    local n="${1:?Usage: ./manage.sh gateway <N>}"
    echo "Starting OpenClaw gateway in openclaw-${n}..."
    docker exec -it "openclaw-${n}" openclaw gateway --port 18789 --verbose
}

cmd_onboard() {
    local n="${1:?Usage: ./manage.sh onboard <N>}"
    echo "Running OpenClaw onboarding in openclaw-${n}..."
    docker exec -it "openclaw-${n}" openclaw onboard
}

cmd_add() {
    local n="${1:?Usage: ./manage.sh add <N>}"
    # Determine which network to create/use for this container
    local net_name="openclaw-containers_net-oc${n}"
    mkdir -p "shared/openclaw-${n}"

    # Create the network if it doesn't exist
    docker network inspect "$net_name" >/dev/null 2>&1 || \
        docker network create --driver bridge "$net_name"

    # Connect the proxy to this new network
    docker network connect "$net_name" api-proxy 2>/dev/null || true

    echo "Starting openclaw-${n}..."
    docker run -d \
        --name "openclaw-${n}" \
        --hostname "openclaw-${n}" \
        --network "$net_name" \
        -v "${SCRIPT_DIR}/shared/openclaw-${n}:/workspace" \
        -e "ANTHROPIC_BASE_URL=http://api-proxy:18080/anthropic" \
        -e "ANTHROPIC_API_KEY=proxy" \
        -e "OPENAI_BASE_URL=http://api-proxy:18080/openai" \
        -e "OPENAI_API_KEY=proxy" \
        --cpus 2.0 \
        --memory 4g \
        --security-opt no-new-privileges:true \
        --cap-drop ALL \
        -it \
        --restart unless-stopped \
        openclaw-sandbox
    echo "openclaw-${n} is running."
}

cmd_rm() {
    local n="${1:?Usage: ./manage.sh rm <N>}"
    echo "Stopping and removing openclaw-${n}..."
    docker rm -f "openclaw-${n}" 2>/dev/null || true
    echo "Done. Shared files remain in shared/openclaw-${n}/"
}

cmd_logs() {
    local n="${1:?Usage: ./manage.sh logs <N>}"
    docker logs -f "openclaw-${n}"
}

cmd_exec() {
    local n="${1:?Usage: ./manage.sh exec <N> <cmd>}"
    shift
    docker exec -it "openclaw-${n}" "$@"
}

cmd_proxy_logs() {
    docker logs -f api-proxy
}

# ── Dispatch ──────────────────────────────────────────────────────

case "${1:-}" in
    build)      cmd_build ;;
    up)         cmd_up ;;
    down)       cmd_down ;;
    status)     cmd_status ;;
    clean)      cmd_clean ;;
    connect)    cmd_connect "${2:-}" ;;
    run)        shift; cmd_run "$@" ;;
    gateway)    cmd_gateway "${2:-}" ;;
    onboard)    cmd_onboard "${2:-}" ;;
    add)        cmd_add "${2:-}" ;;
    rm)         cmd_rm "${2:-}" ;;
    logs)       cmd_logs "${2:-}" ;;
    exec)       shift; cmd_exec "$@" ;;
    proxy-logs) cmd_proxy_logs ;;
    *)          usage ;;
esac
