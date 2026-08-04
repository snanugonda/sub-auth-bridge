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
DOCKER_CONTAINER="hub"
DOCKER_IMAGE="hub"
# Joined so other containers can reach this one by container name
# (http://hub:8787) instead of a host port at all — sidesteps the
# loopback/host.docker.internal reachability problem entirely. Created if
# it doesn't already exist. Override with DOCKER_NETWORK= if ever needed
# (empty string disables joining any network).
DOCKER_NETWORK="${DOCKER_NETWORK-my-hub-net}"

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

    local network_args=()
    if [ -n "$DOCKER_NETWORK" ]; then
      if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        echo "Creating Docker network '$DOCKER_NETWORK'..."
        docker network create "$DOCKER_NETWORK" >/dev/null
      fi
      network_args=(--network "$DOCKER_NETWORK")
    fi

    if [ "$PORT_EXPLICIT" = true ]; then
      if port_in_use "$PORT"; then
        c_red "Port $PORT (set via \$PORT) is already in use. Pick a different PORT or free it first."
        exit 1
      fi
      docker run -d --name "$DOCKER_CONTAINER" ${network_args[@]+"${network_args[@]}"} -p "$PORT:8787" \
        -v "$HOME/.open-ai-sub-auth:/data/auth" \
        -e OPEN_AI_SUB_AUTH_DIR=/data/auth \
        "$DOCKER_IMAGE" >/dev/null
      SERVICE_PORT="$PORT"
    else
      # Bind only the container port, no fixed host port — Docker/the OS
      # picks a free ephemeral one, on loopback only. This is what actually
      # fixes "port 8787 already taken by some other container": we don't
      # ask for 8787 at all unless the caller explicitly wants it.
      docker run -d --name "$DOCKER_CONTAINER" ${network_args[@]+"${network_args[@]}"} -p "127.0.0.1::8787" \
        -v "$HOME/.open-ai-sub-auth:/data/auth" \
        -e OPEN_AI_SUB_AUTH_DIR=/data/auth \
        "$DOCKER_IMAGE" >/dev/null
      SERVICE_PORT="$(docker port "$DOCKER_CONTAINER" 8787 | tail -1 | sed -E 's/.*:([0-9]+)$/\1/')"
    fi
    echo "$SERVICE_PORT" > "$SERVICE_PORT_FILE"
    c_green "Service running in Docker on http://localhost:$SERVICE_PORT"
    if [ -n "$DOCKER_NETWORK" ]; then
      echo "Also reachable from other containers on network '$DOCKER_NETWORK' as: http://$DOCKER_CONTAINER:8787"
    fi
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

# Shared by setup/update: waits for /api/health, then sends a real test
# chat message. Exits non-zero on either failure so callers' numbered-step
# scripts stop cleanly instead of reporting false success.
verify_service_health() {
  local label="$1"
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
  reply="$(cmd_chat "Reply with exactly: $label ok" 2>&1)" || {
    c_red "Test chat call failed: $reply"
    exit 1
  }
  echo "Response: $reply"
}

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
  verify_service_health "setup"
  echo
  c_green "Setup complete. Service running on http://localhost:$SERVICE_PORT"
}

# CI/CD-shaped local pipeline for an already-set-up machine: pull -> install
# -> build (fails fast if code doesn't even compile, before touching the
# running service) -> doctor (informational) -> restart -> verify. Assumes
# you're already signed in — doesn't touch auth at all, unlike 'setup'.
cmd_update() {
  echo "== 1/6: pull latest =="
  if ! git -C "$ROOT_DIR" pull --ff-only; then
    c_red "git pull --ff-only failed — resolve manually (uncommitted changes, diverged history, or a real conflict) and re-run."
    exit 1
  fi

  echo
  echo "== 2/6: install =="
  cmd_install

  echo
  echo "== 3/6: build =="
  cmd_build

  echo
  echo "== 4/6: doctor =="
  (cmd_doctor) 2>&1 || true

  echo
  echo "== 5/6: restart service =="
  cmd_restart auto

  echo
  echo "== 6/6: verify =="
  verify_service_health "update"
  echo
  c_green "Update complete. Service running on http://localhost:$SERVICE_PORT"
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

  # launchd and cron both run jobs with a minimal system PATH
  # (/usr/bin:/bin:/usr/sbin:/sbin) — NOT your interactive shell's PATH, so
  # `node` (wherever it's actually installed — Homebrew, nvm, etc.) isn't
  # found there even though it works fine in a normal terminal. Resolve it
  # now, in the shell that's actually running this command (which does have
  # the right PATH), and bake that directory into the scheduled job's
  # environment instead of hoping the default PATH happens to include it.
  if ! have node; then
    c_red "node not found in this shell's PATH — can't resolve where to point the scheduled job. Install Node or fix your PATH, then retry."
    exit 1
  fi
  local node_dir
  node_dir="$(dirname "$(command -v node)")"
  local job_path="$node_dir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

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
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$job_path</string>
  </dict>
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
      # Force-reload so a PATH fix actually takes effect on an already-running agent.
      launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null \
        || launchctl load "$LAUNCHD_PLIST"
      c_green "Installed launchd agent: $LAUNCHD_LABEL (every ${SYNC_INTERVAL_SECONDS}s)"
      echo "Plist: $LAUNCHD_PLIST"
      echo "Log: $log_file"
      ;;
    Linux)
      local cron_line="* * * * * PATH=$job_path /bin/bash $sync_script >> $log_file 2>&1 $CRON_MARKER"
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
      echo "(none — either not running in node mode, or running via docker: run 'docker logs hub' separately if needed)"
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
# verify-auto-sync — end-to-end proof the scheduler actually fires, not just
# that it's registered. Run this yourself (not via an agent): registering a
# launchd/cron job is the kind of host-level action that needs a real
# permission grant, not a scripted one.
# ============================================================================

cmd_verify_auto_sync() {
  mkdir -p "$STATE_DIR"
  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local out="$STATE_DIR/verify-auto-sync-$timestamp.txt"
  local log_file="$STATE_DIR/openclaw-sync.log"

  # Baseline: what does the log look like BEFORE we (re-)enable? Needed to
  # tell "the scheduler wrote something new" apart from "the log already
  # had content from a previous run" — file existing/non-empty isn't proof
  # of anything by itself.
  local baseline_mtime="none"
  local baseline_lines=0
  if [ -f "$log_file" ]; then
    baseline_mtime="$(stat -f %m "$log_file" 2>/dev/null || stat -c %Y "$log_file" 2>/dev/null)"
    baseline_lines="$(wc -l < "$log_file" | tr -d ' ')"
  fi

  echo "Step 1/4: enabling auto-sync (safe to run even if already enabled)..."
  local enable_output
  enable_output="$(cmd_enable_auto_sync 2>&1)" || true
  echo "$enable_output"

  echo
  echo "Step 2/4: checking registration status..."
  local status_output
  status_output="$(cmd_auto_sync_status 2>&1)" || true
  echo "$status_output"

  echo
  echo "Step 3/4: waiting for the scheduler to actually fire (up to 150s)."
  echo "launchd's RunAtLoad should fire almost immediately; cron waits for the next minute boundary — this can take a little while, that's normal."
  local waited=0
  local poll_interval=5
  local max_wait=150
  local fired=false
  while [ "$waited" -lt "$max_wait" ]; do
    if [ -f "$log_file" ]; then
      local current_mtime
      current_mtime="$(stat -f %m "$log_file" 2>/dev/null || stat -c %Y "$log_file" 2>/dev/null)"
      if [ "$baseline_mtime" = "none" ] || [ "$current_mtime" != "$baseline_mtime" ]; then
        fired=true
        break
      fi
    fi
    sleep "$poll_interval"
    waited=$((waited + poll_interval))
    echo "  ...waited ${waited}s"
  done

  echo
  echo "Step 4/4: writing report..."

  local new_content=""
  local verdict=""
  local verdict_detail=""

  if [ "$fired" = true ]; then
    if [ "$baseline_lines" -gt 0 ]; then
      new_content="$(tail -n "+$((baseline_lines + 1))" "$log_file")"
    else
      new_content="$(cat "$log_file" 2>/dev/null)"
    fi

    if echo "$new_content" | grep -qi "no openclaw auth database found"; then
      verdict="PASS (scheduler) / INCONCLUSIVE (no OpenClaw data here)"
      verdict_detail="The scheduler fired on time and ran the sync script — launchd/cron registration itself works. It reported no OpenClaw database on this machine, which is expected here and isn't a failure of auto-sync. For a full content test, run this same command on a machine that has OpenClaw installed."
    elif echo "$new_content" | grep -qi "credential unchanged since last sync\|synced updated"; then
      verdict="PASS"
      verdict_detail="The scheduler fired on time and the sync script ran successfully against real OpenClaw data."
    elif [ -z "$new_content" ]; then
      verdict="INCONCLUSIVE"
      verdict_detail="The log's mtime changed but there's no readable new content — something touched the file without writing a recognizable line. Check the full log tail below."
    else
      # Default to FAIL for anything that isn't a known-good pattern, rather
      # than trying to enumerate every possible error phrase (e.g. "node:
      # command not found" doesn't contain the words "error" or "fail" —
      # missing that exact gap is what motivated this default in the first
      # place). Unrecognized output from a script that only ever prints a
      # few known messages is worth flagging, not shrugging off.
      verdict="FAIL"
      verdict_detail="The scheduler fired, but the sync script's output didn't match any known-success pattern — likely an error. See the log excerpt below."
    fi
  else
    verdict="FAIL"
    verdict_detail="No log activity observed within ${max_wait}s of enabling. The scheduler likely isn't registered correctly — check the registration status output above for errors."
  fi

  {
    echo "===== VERDICT: $verdict ====="
    echo "$verdict_detail"
    echo
    echo "open-ai-sub-auth auto-sync verification — $timestamp UTC"
    echo "host: $(uname -a)"
    echo
    echo "===== enable-auto-sync output ====="
    echo "$enable_output"
    echo
    echo "===== auto-sync-status output ====="
    echo "$status_output"
    echo
    echo "===== waited ${waited}s for a scheduler tick; fired: $fired ====="
    echo
    echo "===== new log content since baseline ====="
    if [ -n "$new_content" ]; then
      echo "$new_content"
    else
      echo "(none)"
    fi
    echo
    echo "===== full log tail (last 50 lines), for context ====="
    if [ -f "$log_file" ]; then
      tail -n 50 "$log_file"
    else
      echo "(log file does not exist)"
    fi
  } | sed -E 's/\x1b\[[0-9;]*m//g' > "$out"

  echo
  if [ "$verdict" = "PASS" ]; then
    c_green "Verdict: $verdict"
  elif [ "$verdict" = "FAIL" ]; then
    c_red "Verdict: $verdict"
  else
    c_yellow "Verdict: $verdict"
  fi
  c_green "Full report written to: $out"
  echo "Share that file back — no tokens in it, same guarantee as debug-bundle."
  echo "To remove the scheduled job when you're done testing: ./scripts/repo.sh disable-auto-sync"
}

# ============================================================================
# help / dispatch
# ============================================================================

cmd_help() {
  cat <<EOF
Usage: ./scripts/repo.sh <command> [args]

  setup            first-run: install, sign in (asks: new login or import
                   from OpenClaw), start the service, health check, test chat
  update           already set up: git pull --ff-only, install, build (fails
                   fast if it doesn't compile), doctor, restart, verify —
                   the CI/CD-shaped "pull latest and redeploy locally" loop
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
  verify-auto-sync    run yourself (not via an agent): enables auto-sync,
                   waits for a real scheduler tick, writes a timestamped
                   pass/fail report to share back — proves it actually
                   fires, not just that it's registered
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
    update) cmd_update ;;
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
    verify-auto-sync) cmd_verify_auto_sync ;;
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
