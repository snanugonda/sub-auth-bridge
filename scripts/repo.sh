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
SERVICE_PORT_FILE="$STATE_DIR/service-port"
DOCKER_CONTAINER="open-ai-sub-auth-service"
DOCKER_IMAGE="open-ai-sub-auth-service"

# If the caller set PORT explicitly, that's a hard requirement — start fails
# loudly if it's taken, same as before. Otherwise the port is chosen
# dynamically at start time (Docker's own ephemeral allocator, or a free-port
# probe for node mode) and persisted to SERVICE_PORT_FILE so every other
# command (status/chat/logs/stop/debug-bundle) in a later invocation can find
# the currently-running instance without guessing 8787.
PORT_EXPLICIT=false
if [ -n "${PORT:-}" ]; then PORT_EXPLICIT=true; fi

resolve_service_port() {
  if [ "$PORT_EXPLICIT" = true ]; then
    echo "$PORT"
  elif [ -f "$SERVICE_PORT_FILE" ]; then
    cat "$SERVICE_PORT_FILE"
  else
    echo 8787
  fi
}
SERVICE_PORT="$(resolve_service_port)"

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
  local mode="${1:-new}"
  if [ "$mode" = "openclaw" ] || [ "$mode" = "--from-openclaw" ]; then
    echo "Importing OAuth credential from an existing OpenClaw install..."
    if ! "$ROOT_DIR/scripts/import-openclaw-auth.sh"; then
      c_yellow "Import failed. Falling back to a fresh login."
      (cd "$DEPENDENCY_DIR" && npm run login)
    fi
  else
    echo "Running OAuth login (writes to ~/.open-ai-sub-auth/auth.json, shared by all packages)..."
    (cd "$DEPENDENCY_DIR" && npm run login)
  fi
}

# ============================================================================
# start / stop / restart / status for the service
# ============================================================================

port_pid() {
  lsof -ti ":$SERVICE_PORT" 2>/dev/null || true
}

port_in_use() {
  [ -n "$(lsof -ti ":$1" 2>/dev/null || true)" ]
}

# Asks the OS for a free ephemeral port by binding to port 0 and reading
# back what got assigned, then releasing it — more reliable than scanning
# upward from 8787 ourselves (no manual bookkeeping of "which port did I
# already try"), at the cost of a small, well-understood race between the
# probe releasing the port and the real process binding it moments later.
find_free_port() {
  node -e "
    const s = require('net').createServer();
    s.listen(0, '127.0.0.1', () => {
      const p = s.address().port;
      s.close(() => console.log(p));
    });
  "
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

  # Guard against a second start only when WE'RE already tracking a running
  # instance — not by checking whether some unrelated process happens to be
  # on port 8787 (that was the original bug: a container on that port from
  # something else entirely blocked us from ever starting).
  if have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"; then
    c_yellow "Docker container '$DOCKER_CONTAINER' is already running. Run './scripts/repo.sh stop' first."
    exit 1
  fi
  if [ -f "$NODE_PID_FILE" ] && kill -0 "$(cat "$NODE_PID_FILE")" 2>/dev/null; then
    c_yellow "A local node process (pid $(cat "$NODE_PID_FILE")) is already running. Run './scripts/repo.sh stop' first."
    exit 1
  fi

  mkdir -p "$STATE_DIR"

  if [ "$mode" = "docker" ]; then
    echo "Starting service in Docker..."
    docker build -t "$DOCKER_IMAGE" "$SERVICE_DIR"
    docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true

    if [ "$PORT_EXPLICIT" = true ]; then
      if port_in_use "$PORT"; then
        c_red "Port $PORT (set via \$PORT) is already in use. Pick a different PORT or free it first."
        exit 1
      fi
      docker run -d --name "$DOCKER_CONTAINER" -p "$PORT:8787" \
        -v "$HOME/.open-ai-sub-auth:/data/auth" \
        -e OPEN_AI_SUB_AUTH_DIR=/data/auth \
        "$DOCKER_IMAGE" >/dev/null
      SERVICE_PORT="$PORT"
    else
      # Bind only the container port, no fixed host port — Docker/the OS
      # picks a free ephemeral one, on loopback only. This is what actually
      # fixes "port 8787 already taken by some other container": we don't
      # ask for 8787 at all unless the caller explicitly wants it.
      docker run -d --name "$DOCKER_CONTAINER" -p "127.0.0.1::8787" \
        -v "$HOME/.open-ai-sub-auth:/data/auth" \
        -e OPEN_AI_SUB_AUTH_DIR=/data/auth \
        "$DOCKER_IMAGE" >/dev/null
      SERVICE_PORT="$(docker port "$DOCKER_CONTAINER" 8787 | tail -1 | sed -E 's/.*:([0-9]+)$/\1/')"
    fi
    echo "$SERVICE_PORT" > "$SERVICE_PORT_FILE"
    c_green "Service running in Docker on http://localhost:$SERVICE_PORT"
  elif [ "$mode" = "node" ]; then
    echo "Starting service as a local Node process..."
    (cd "$SERVICE_DIR" && npm run build >/dev/null)

    if [ "$PORT_EXPLICIT" = true ]; then
      if port_in_use "$PORT"; then
        c_red "Port $PORT (set via \$PORT) is already in use. Pick a different PORT or free it first."
        exit 1
      fi
      SERVICE_PORT="$PORT"
    else
      SERVICE_PORT="$(find_free_port)"
    fi

    # No subshell grouping around the background job — that would make $!
    # capture a wrapper PID instead of the actual node process, orphaning it
    # on stop. cd in the current shell, launch directly, cd back.
    local prev_dir="$PWD"
    cd "$SERVICE_DIR"
    PORT="$SERVICE_PORT" nohup node dist/server.js >"$STATE_DIR/service.log" 2>&1 &
    echo $! >"$NODE_PID_FILE"
    cd "$prev_dir"
    sleep 1
    echo "$SERVICE_PORT" > "$SERVICE_PORT_FILE"
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
  rm -f "$SERVICE_PORT_FILE"

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
# setup (first run) / teardown
# ============================================================================

cmd_setup() {
  echo "== 1/5: dependency checks =="
  if ! have node; then
    c_red "node not found. Install Node 18+ and re-run."
    exit 1
  fi
  if ! have docker || ! docker info >/dev/null 2>&1; then
    c_yellow "docker not found or not running — will start the service as a plain Node process instead."
  fi

  echo
  echo "== 2/5: install =="
  cmd_install

  echo
  echo "== 3/5: sign in =="
  if [ -f "$AUTH_FILE" ]; then
    c_green "Already signed in (found $AUTH_FILE) — skipping."
  else
    local answer
    if have "$ROOT_DIR/scripts/import-openclaw-auth.sh" && [ -f "$HOME/.openclaw/agents/main/agent/openclaw-agent.sqlite" ]; then
      echo "An OpenClaw install with OpenAI credentials was detected on this machine."
      read -r -p "Import OpenClaw's existing login instead of signing in again? [Y/n] " answer
      answer="${answer:-y}"
    else
      answer="n"
    fi
    case "$answer" in
      [Yy]*) cmd_login openclaw ;;
      *) cmd_login new ;;
    esac
  fi

  echo
  echo "== 4/5: start the service =="
  cmd_start auto

  echo
  echo "== 5/5: verify =="
  local tries=0
  until curl -sf "http://localhost:$SERVICE_PORT/api/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 20 ]; then
      c_red "Service did not become healthy after 10s."
      exit 1
    fi
    sleep 0.5
  done
  c_green "Health check passed."

  echo "Sending a test chat message..."
  local reply
  reply="$(cmd_chat "Reply with exactly: setup ok" 2>&1)" || {
    c_red "Test chat call failed: $reply"
    exit 1
  }
  echo "Response: $reply"
  echo
  c_green "Setup complete. Service running on http://localhost:$SERVICE_PORT"
}

cmd_teardown() {
  echo "Tearing down this repo's service (not touching OpenClaw, its config, or any other host state)..."
  cmd_stop

  if have docker && docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
    echo "Removing Docker image $DOCKER_IMAGE..."
    docker rmi "$DOCKER_IMAGE" >/dev/null 2>&1 || true
  fi

  if [ -d "$STATE_DIR" ]; then
    echo "Removing $STATE_DIR (pid/log files only)..."
    rm -rf "$STATE_DIR"
  fi

  c_green "Teardown complete."
  echo "Untouched on purpose: ~/.open-ai-sub-auth/auth.json (your login), ~/.openclaw (OpenClaw's own state), node_modules/dist (use 'clean' for those)."
}

# ============================================================================
# OpenClaw auto-sync (opt-in OS scheduler — not installed by 'setup')
# ============================================================================
#
# Registers scripts/import-openclaw-auth.sh to run on a schedule (every 60s)
# so an OpenClaw-linked auth.json never goes stale between manual syncs.
# Purely local, read-only against OpenClaw's DB — see that script's header.
# Nothing here runs unless you explicitly call 'enable-auto-sync'.

SYNC_INTERVAL_SECONDS="${SYNC_INTERVAL_SECONDS:-60}"
LAUNCHD_LABEL="com.open-ai-sub-auth.openclaw-sync"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
CRON_MARKER="# open-ai-sub-auth-openclaw-sync"

cmd_enable_auto_sync() {
  local sync_script="$ROOT_DIR/scripts/import-openclaw-auth.sh"
  mkdir -p "$STATE_DIR"
  local log_file="$STATE_DIR/openclaw-sync.log"

  case "$(uname)" in
    Darwin)
      mkdir -p "$(dirname "$LAUNCHD_PLIST")"
      cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$sync_script</string>
  </array>
  <key>StartInterval</key>
  <integer>$SYNC_INTERVAL_SECONDS</integer>
  <key>StandardOutPath</key>
  <string>$log_file</string>
  <key>StandardErrorPath</key>
  <string>$log_file</string>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF
      launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null \
        || launchctl load "$LAUNCHD_PLIST"
      c_green "Installed launchd agent: $LAUNCHD_LABEL (every ${SYNC_INTERVAL_SECONDS}s)"
      echo "Plist: $LAUNCHD_PLIST"
      echo "Log: $log_file"
      ;;
    Linux)
      local cron_line="* * * * * /bin/bash $sync_script >> $log_file 2>&1 $CRON_MARKER"
      (crontab -l 2>/dev/null | grep -v "$CRON_MARKER"; echo "$cron_line") | crontab -
      c_green "Installed cron entry (every minute — cron's finest granularity)."
      echo "Log: $log_file"
      ;;
    *)
      c_red "Unsupported platform for auto-sync: $(uname). Run the sync script manually or via your own scheduler."
      exit 1
      ;;
  esac
}

cmd_disable_auto_sync() {
  case "$(uname)" in
    Darwin)
      if [ -f "$LAUNCHD_PLIST" ]; then
        launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null \
          || launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
        rm -f "$LAUNCHD_PLIST"
        c_green "Removed launchd agent: $LAUNCHD_LABEL"
      else
        echo "No launchd agent installed."
      fi
      ;;
    Linux)
      if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        (crontab -l 2>/dev/null | grep -v "$CRON_MARKER") | crontab -
        c_green "Removed cron entry."
      else
        echo "No cron entry installed."
      fi
      ;;
    *)
      echo "Nothing to remove on this platform."
      ;;
  esac
}

cmd_auto_sync_status() {
  case "$(uname)" in
    Darwin)
      if [ -f "$LAUNCHD_PLIST" ]; then
        c_green "Installed: $LAUNCHD_PLIST"
        launchctl list "$LAUNCHD_LABEL" 2>/dev/null || c_yellow "Plist present but not loaded — try enable-auto-sync again."
      else
        echo "Not installed."
      fi
      ;;
    Linux)
      if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        c_green "Installed:"
        crontab -l 2>/dev/null | grep "$CRON_MARKER"
      else
        echo "Not installed."
      fi
      ;;
    *)
      echo "Not supported on this platform."
      ;;
  esac
}

# ============================================================================
# debug bundle — one file to share back for analysis
# ============================================================================

cmd_debug_bundle() {
  mkdir -p "$STATE_DIR"
  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local out="$STATE_DIR/diagnostics-$timestamp.txt"

  {
    echo "open-ai-sub-auth diagnostics — $timestamp UTC"
    echo "host: $(uname -a)"
    echo "node: $(node -v 2>/dev/null || echo 'not found')"
    echo "docker: $(docker -v 2>/dev/null || echo 'not found')"
    echo

    echo "===== doctor ====="
    # Subshell: cmd_doctor calls `exit 1` on failure, which would otherwise
    # kill this whole bundle command before the file is written.
    (cmd_doctor) 2>&1 || true
    echo

    echo "===== auto-sync status ====="
    (cmd_auto_sync_status) 2>&1 || true
    echo

    echo "===== service status ====="
    (cmd_status) 2>&1 || true
    echo

    echo "===== openclaw sync log (last 200 lines) ====="
    if [ -f "$STATE_DIR/openclaw-sync.log" ]; then
      tail -n 200 "$STATE_DIR/openclaw-sync.log"
    else
      echo "(none yet at $STATE_DIR/openclaw-sync.log)"
    fi
    echo

    echo "===== service log, node mode only (last 100 lines) ====="
    if [ -f "$STATE_DIR/service.log" ]; then
      tail -n 100 "$STATE_DIR/service.log"
    else
      echo "(none — either not running in node mode, or running via docker: run 'docker logs open-ai-sub-auth-service' separately if needed)"
    fi
    echo

    echo "===== auth.json metadata (redacted — no tokens, ever) ====="
    if [ -f "$AUTH_FILE" ]; then
      node -e "
        const a = require(process.argv[1]);
        console.log(JSON.stringify({
          source: a.source ?? null,
          expires_at_iso: new Date(a.expires_at).toISOString(),
          expires_in_min: Math.round((a.expires_at - Date.now()) / 60000),
        }, null, 2));
      " "$AUTH_FILE" 2>&1
    else
      echo "(no auth.json found)"
    fi
  } | sed -E 's/\x1b\[[0-9;]*m//g' > "$out"

  c_green "Diagnostics written to: $out"
  echo "Contains: doctor + auto-sync + service status, sync/service log tails, and redacted auth.json metadata (source/expiry only — no tokens). Safe to share as-is."
}

# ============================================================================
# help / dispatch
# ============================================================================

cmd_help() {
  cat <<EOF
Usage: ./scripts/repo.sh <command> [args]

  setup            first-run: install, sign in (asks: new login or import
                   from OpenClaw), start the service, health check, test chat
  install          npm install in all 3 packages
  build            build/typecheck all 3 packages
  login [new|openclaw]   run OAuth login, or import from an existing OpenClaw install
  start [docker|node]   start packages/service (auto-detects docker if
                   available); picks a free port automatically unless PORT
                   is set, tracked in .repo-state/service-port
  stop             stop the running service, however it was started
  restart [docker|node]
  status           auth status + service status + health check
  logs             tail service logs (docker or local)
  chat "prompt"    send a chat message (via running service, else dependency package)
  doctor           full environment health check
  teardown         stop + remove this service's docker image + state files
                   (never touches OpenClaw or your auth.json)
  clean            remove node_modules/dist in all 3 packages
  enable-auto-sync    install a launchd (macOS) / cron (Linux) job that runs
                   the OpenClaw sync every ${SYNC_INTERVAL_SECONDS:-60}s (opt-in, not run by 'setup')
  disable-auto-sync   remove that scheduled job
  auto-sync-status    check whether it's currently installed
  debug-bundle     write one timestamped diagnostics file (doctor, auto-sync
                   status, log tails, redacted auth metadata) to share back
  help             this message
EOF
}

main() {
  local command="${1:-help}"
  shift || true
  case "$command" in
    setup) cmd_setup ;;
    install) cmd_install ;;
    build) cmd_build ;;
    login) cmd_login "${1:-new}" ;;
    start) cmd_start "${1:-auto}" ;;
    stop) cmd_stop ;;
    restart) cmd_restart "${1:-auto}" ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    chat) cmd_chat "$@" ;;
    doctor) cmd_doctor ;;
    teardown) cmd_teardown ;;
    clean) cmd_clean ;;
    enable-auto-sync) cmd_enable_auto_sync ;;
    disable-auto-sync) cmd_disable_auto_sync ;;
    auto-sync-status) cmd_auto_sync_status ;;
    debug-bundle) cmd_debug_bundle ;;
    help|-h|--help) cmd_help ;;
    *)
      c_red "Unknown command: $command"
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
