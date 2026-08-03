#!/usr/bin/env bash
# Single entrypoint for repo maintenance: install, build, login, start/stop
# the service, status, doctor, logs, chat, clean. Run `./scripts/repo.sh help`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPENDENCY_DIR="$ROOT_DIR/packages/dependency"
SINGLE_FILE_DIR="$ROOT_DIR/packages/single-file"
SERVICE_DIR="$ROOT_DIR/packages/service"
AUTH_FILE="$HOME/.open-ai-sub-auth/auth.json"
STATE_DIR="$ROOT_DIR/.repo-state"
NODE_PID_FILE="$STATE_DIR/service-node.pid"
DOCKER_CONTAINER="open-ai-sub-auth-service"
DOCKER_IMAGE="open-ai-sub-auth-service"
SERVICE_PORT="${PORT:-8787}"

c_red() { printf '\033[31m%s\033[0m\n' "$1"; }
c_green() { printf '\033[32m%s\033[0m\n' "$1"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ============================================================================
# install / build
# ============================================================================

cmd_install() {
  for dir in "$DEPENDENCY_DIR" "$SINGLE_FILE_DIR" "$SERVICE_DIR"; do
    echo "Installing $(basename "$dir")..."
    (cd "$dir" && npm install)
  done
  c_green "All packages installed."
}

cmd_build() {
  echo "Building dependency..."
  (cd "$DEPENDENCY_DIR" && npm run build)
  echo "Typechecking single-file..."
  (cd "$SINGLE_FILE_DIR" && npm run typecheck)
  echo "Building service..."
  (cd "$SERVICE_DIR" && npm run build)
  c_green "Build complete."
}

# ============================================================================
# login
# ============================================================================

cmd_login() {
  echo "Running OAuth login (writes to ~/.open-ai-sub-auth/auth.json, shared by all packages)..."
  (cd "$DEPENDENCY_DIR" && npm run login)
}

# ============================================================================
# start / stop / restart / status for the service
# ============================================================================

port_pid() {
  lsof -ti ":$SERVICE_PORT" 2>/dev/null || true
}

cmd_start() {
  local mode="${1:-auto}"
  if [ ! -f "$AUTH_FILE" ]; then
    c_red "Not signed in. Run './scripts/repo.sh login' first."
    exit 1
  fi

  if [ "$mode" = "auto" ]; then
    if have docker && docker info >/dev/null 2>&1; then
      mode="docker"
    else
      mode="node"
    fi
  fi

  if [ -n "$(port_pid)" ]; then
    c_yellow "Something is already listening on port $SERVICE_PORT. Run './scripts/repo.sh stop' first."
    exit 1
  fi

  mkdir -p "$STATE_DIR"

  if [ "$mode" = "docker" ]; then
    echo "Starting service in Docker..."
    docker build -t "$DOCKER_IMAGE" "$SERVICE_DIR"
    docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$DOCKER_CONTAINER" -p "$SERVICE_PORT:8787" \
      -v "$HOME/.open-ai-sub-auth:/data/auth" \
      -e OPEN_AI_SUB_AUTH_DIR=/data/auth \
      "$DOCKER_IMAGE" >/dev/null
    c_green "Service running in Docker on http://localhost:$SERVICE_PORT"
  elif [ "$mode" = "node" ]; then
    echo "Starting service as a local Node process..."
    (cd "$SERVICE_DIR" && npm run build >/dev/null)
    # No subshell grouping around the background job — that would make $!
    # capture a wrapper PID instead of the actual node process, orphaning it
    # on stop. cd in the current shell, launch directly, cd back.
    local prev_dir="$PWD"
    cd "$SERVICE_DIR"
    PORT="$SERVICE_PORT" nohup node dist/server.js >"$STATE_DIR/service.log" 2>&1 &
    echo $! >"$NODE_PID_FILE"
    cd "$prev_dir"
    sleep 1
    c_green "Service running (pid $(cat "$NODE_PID_FILE")) on http://localhost:$SERVICE_PORT"
  else
    c_red "Unknown mode: $mode (use 'docker' or 'node')"
    exit 1
  fi
}

cmd_stop() {
  local stopped=false
  if have docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"; then
    echo "Stopping Docker container..."
    docker rm -f "$DOCKER_CONTAINER" >/dev/null
    stopped=true
  fi
  if [ -f "$NODE_PID_FILE" ]; then
    local pid
    pid="$(cat "$NODE_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "Stopping local Node process (pid $pid)..."
      kill "$pid"
      stopped=true
    fi
    rm -f "$NODE_PID_FILE"
  fi
  # Defense in depth: if tracking (pidfile/docker name) missed the real
  # process — e.g. it was reparented after an earlier bug — sweep the port
  # directly, but only kill it if it's actually our service.
  local leftover
  leftover="$(port_pid)"
  if [ -n "$leftover" ]; then
    for pid in $leftover; do
      if ps -p "$pid" -o command= 2>/dev/null | grep -q "dist/server.js"; then
        echo "Killing untracked service process (pid $pid) still on port $SERVICE_PORT..."
        kill "$pid" 2>/dev/null || true
        stopped=true
      else
        c_yellow "Port $SERVICE_PORT held by pid $pid, not our service — leaving it alone."
      fi
    done
  fi
  if [ "$stopped" = true ]; then
    c_green "Service stopped."
  else
    echo "Nothing to stop."
  fi
}

cmd_restart() {
  cmd_stop
  cmd_start "${1:-auto}"
}

cmd_status() {
  echo "== Auth =="
  if [ -f "$AUTH_FILE" ]; then
    node -e '
      const auth = require(process.argv[1]);
      const minsLeft = Math.round((auth.expires_at - Date.now()) / 60000);
      console.log("Signed in: yes");
      console.log("Account ID:", auth.account_id);
      console.log("Access token expires in:", minsLeft, "min");
    ' "$AUTH_FILE" 2>/dev/null || c_red "Auth file exists but could not be parsed."
  else
    c_yellow "Signed in: no (run './scripts/repo.sh login')"
  fi

  echo
  echo "== Service =="
  if have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"; then
    echo "Running in Docker (container: $DOCKER_CONTAINER)"
  elif [ -f "$NODE_PID_FILE" ] && kill -0 "$(cat "$NODE_PID_FILE")" 2>/dev/null; then
    echo "Running as local Node process (pid $(cat "$NODE_PID_FILE"))"
  else
    echo "Not running"
  fi

  if [ -n "$(port_pid)" ]; then
    local health
    health="$(curl -sf "http://localhost:$SERVICE_PORT/api/health" 2>/dev/null || echo "unreachable")"
    echo "Health check on :$SERVICE_PORT: $health"
  fi
}

cmd_logs() {
  if have docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"; then
    docker logs -f "$DOCKER_CONTAINER"
  elif [ -f "$STATE_DIR/service.log" ]; then
    tail -f "$STATE_DIR/service.log"
  else
    c_yellow "No running service found to show logs for."
  fi
}

# ============================================================================
# doctor
# ============================================================================

cmd_doctor() {
  local problems=0

  echo "== Node =="
  if have node; then
    local v
    v="$(node -v)"
    echo "node $v found"
    local major="${v#v}"
    major="${major%%.*}"
    if [ "$major" -lt 18 ]; then
      c_red "Node 18+ required, found $v"
      problems=$((problems + 1))
    fi
  else
    c_red "node not found"
    problems=$((problems + 1))
  fi

  echo
  echo "== Docker (optional, only needed for packages/service container) =="
  if have docker; then
    if docker info >/dev/null 2>&1; then
      c_green "docker found and running"
    else
      c_yellow "docker found but the daemon isn't running"
    fi
  else
    c_yellow "docker not found (fine unless you want to containerize the service)"
  fi

  echo
  echo "== Dependencies installed =="
  for dir in "$DEPENDENCY_DIR" "$SINGLE_FILE_DIR" "$SERVICE_DIR"; do
    local name
    name="$(basename "$dir")"
    if [ -d "$dir/node_modules" ]; then
      c_green "$name: node_modules present"
    else
      c_yellow "$name: node_modules missing — run './scripts/repo.sh install'"
      problems=$((problems + 1))
    fi
  done

  echo
  echo "== Auth =="
  if [ -f "$AUTH_FILE" ]; then
    local perms
    perms="$(stat -f '%Lp' "$AUTH_FILE" 2>/dev/null || stat -c '%a' "$AUTH_FILE" 2>/dev/null || echo '?')"
    c_green "auth.json found (permissions: $perms)"
    if [ "$perms" != "600" ]; then
      c_yellow "expected permissions 600, got $perms"
    fi
    node -e '
      const auth = require(process.argv[1]);
      const minsLeft = Math.round((auth.expires_at - Date.now()) / 60000);
      if (minsLeft < 0) console.log("WARNING: access token expired " + (-minsLeft) + " min ago (will auto-refresh on next call)");
      else console.log("Access token valid for another " + minsLeft + " min");
    ' "$AUTH_FILE" 2>/dev/null || c_red "auth.json exists but failed to parse as JSON"
  else
    c_yellow "Not signed in — run './scripts/repo.sh login'"
    problems=$((problems + 1))
  fi

  echo
  echo "== Port $SERVICE_PORT =="
  if [ -n "$(port_pid)" ]; then
    echo "In use by pid(s): $(port_pid)"
  else
    echo "Free"
  fi

  echo
  if [ "$problems" -eq 0 ]; then
    c_green "Doctor: all checks passed."
  else
    c_red "Doctor: $problems issue(s) found."
    exit 1
  fi
}

# ============================================================================
# chat / clean
# ============================================================================

cmd_chat() {
  local prompt="${*:-Say hello in one sentence.}"
  if [ -n "$(port_pid)" ]; then
    curl -sf "http://localhost:$SERVICE_PORT/api/chat" \
      -H "Content-Type: application/json" \
      -d "$(node -e 'console.log(JSON.stringify({messages:[{role:"user",content:process.argv[1]}]}))' "$prompt")" \
      | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).text))'
  else
    (cd "$DEPENDENCY_DIR" && npm run chat -- "$prompt")
  fi
}

cmd_clean() {
  for dir in "$DEPENDENCY_DIR" "$SINGLE_FILE_DIR" "$SERVICE_DIR"; do
    echo "Cleaning $(basename "$dir")..."
    rm -rf "$dir/node_modules" "$dir/dist"
  done
  c_green "Cleaned. Run './scripts/repo.sh install' to reinstall."
}

# ============================================================================
# help / dispatch
# ============================================================================

cmd_help() {
  cat <<EOF
Usage: ./scripts/repo.sh <command> [args]

  install          npm install in all 3 packages
  build            build/typecheck all 3 packages
  login            run OAuth login (shared across all packages)
  start [docker|node]   start packages/service (auto-detects docker if available)
  stop             stop the running service, however it was started
  restart [docker|node]
  status           auth status + service status + health check
  logs             tail service logs (docker or local)
  chat "prompt"    send a chat message (via running service, else dependency package)
  doctor           full environment health check
  clean            remove node_modules/dist in all 3 packages
  help             this message
EOF
}

main() {
  local command="${1:-help}"
  shift || true
  case "$command" in
    install) cmd_install ;;
    build) cmd_build ;;
    login) cmd_login ;;
    start) cmd_start "${1:-auto}" ;;
    stop) cmd_stop ;;
    restart) cmd_restart "${1:-auto}" ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    chat) cmd_chat "$@" ;;
    doctor) cmd_doctor ;;
    clean) cmd_clean ;;
    help|-h|--help) cmd_help ;;
    *)
      c_red "Unknown command: $command"
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
