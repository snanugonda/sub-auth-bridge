#!/usr/bin/env bash
# Mirrors the OpenAI/ChatGPT OAuth credential from a local OpenClaw install
# into ~/.open-ai-sub-auth/auth.json, so you don't have to log in again if
# OpenClaw is already signed in on this machine.
#
# Safe to run repeatedly (e.g. on a schedule) — this is the ONLY place in
# the whole repo that ever reads OpenClaw's storage; the 3 packages never
# do. It only ever COPIES OpenClaw's current token, read-only, and never
# calls OpenAI's refresh endpoint itself. That matters: OpenAI's refresh
# tokens are single-use/rotating, so if this script (or any of our 3
# packages) called refresh on an OpenClaw-derived token, it would silently
# invalidate OpenClaw's own live session. See auth.ts's `source: "openclaw"`
# handling in each package for the other half of that guarantee.
#
# Skips the write entirely when OpenClaw's stored token hasn't changed
# since the last run, and writes via temp-file + rename when it has, so a
# consumer reading auth.json concurrently never observes a partial file.
#
# OpenClaw's real storage (verified against its source, not guessed):
#   ~/.openclaw/agents/main/agent/openclaw-agent.sqlite
#   table auth_profile_store, row store_key='primary', column store_json
#   -> { version, profiles: { "openai:default": { type:"oauth", access,
#        refresh, expires, accountId, idToken, ... } } }
#
# Fragility warning: this depends on OpenClaw's internal, undocumented
# SQLite schema. If OpenClaw changes it in a future release, this script
# may need updating. If it fails, the fallback is always:
#   ./scripts/repo.sh login
set -euo pipefail

OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
OPENCLAW_AGENT_DIR="${OPENCLAW_AGENT_DIR:-$OPENCLAW_STATE_DIR/agents/main/agent}"
OPENCLAW_DB="$OPENCLAW_AGENT_DIR/openclaw-agent.sqlite"
AUTH_DIR="$HOME/.open-ai-sub-auth"
AUTH_FILE="$AUTH_DIR/auth.json"

c_red() { printf '\033[31m%s\033[0m\n' "$1"; }
c_green() { printf '\033[32m%s\033[0m\n' "$1"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

if ! command -v sqlite3 >/dev/null 2>&1; then
  c_red "sqlite3 CLI not found — can't read OpenClaw's database. Falling back: run './scripts/repo.sh login' instead."
  exit 1
fi

if [ ! -f "$OPENCLAW_DB" ]; then
  c_red "No OpenClaw auth database found at: $OPENCLAW_DB"
  echo "(Set OPENCLAW_STATE_DIR or OPENCLAW_AGENT_DIR if OpenClaw uses a non-default location.)"
  echo "Falling back: run './scripts/repo.sh login' instead."
  exit 1
fi

# Read-only query — SQLite supports opening via a read-only URI so this can
# never write to OpenClaw's database, even by accident.
#
# A read-only open needs the DB's -wal/-shm sidecar files to already exist
# if it's in WAL mode (can't create them itself in read-only mode). Against
# OpenClaw's real, live database those always exist from its own normal
# use, but transient contention is still possible on a shared file this
# script doesn't control — retry briefly before giving up for real, since
# this runs unattended and repeatedly.
raw_json=""
for attempt in 1 2 3; do
  raw_json="$(sqlite3 -readonly -json "file:$OPENCLAW_DB?mode=ro" \
    "SELECT store_json FROM auth_profile_store WHERE store_key = 'primary';" 2>/dev/null || true)"
  [ -n "$raw_json" ] && [ "$raw_json" != "[]" ] && break
  sleep 0.3
done

if [ -z "$raw_json" ] || [ "$raw_json" = "[]" ]; then
  c_red "OpenClaw's auth_profile_store table is empty or unreadable."
  echo "Falling back: run './scripts/repo.sh login' instead."
  exit 1
fi

node -e '
const fs = require("fs");
const path = require("path");

const raw = JSON.parse(process.argv[1]);
const storeJson = raw?.[0]?.store_json;
if (!storeJson) {
  console.error("Could not find store_json in query result.");
  process.exit(1);
}

const store = JSON.parse(storeJson);
const profiles = store?.profiles ?? {};

// Prefer the documented default key, fall back to any oauth-type openai profile
// (covers renamed/multi-account setups without hardcoding one key).
let cred = profiles["openai:default"];
if (!cred) {
  const entry = Object.entries(profiles).find(
    ([, p]) => p?.type === "oauth" && p?.provider === "openai",
  );
  cred = entry?.[1];
}

if (!cred || cred.type !== "oauth" || !cred.access || !cred.refresh) {
  console.error("No OpenAI OAuth credential found in OpenClaw'\''s auth store.");
  process.exit(1);
}

if (!cred.accountId) {
  console.error("OpenClaw credential is missing accountId — cannot use it (this repo requires it for the chatgpt-account-id header).");
  process.exit(1);
}

const authDir = process.argv[2];
const authFile = path.join(authDir, "auth.json");
const candidate = {
  access_token: cred.access,
  refresh_token: cred.refresh,
  id_token: cred.idToken ?? "",
  account_id: cred.accountId,
  expires_at: cred.expires,
  source: "openclaw",
};

let existing = null;
try {
  existing = JSON.parse(fs.readFileSync(authFile, "utf-8"));
} catch {
  // Missing or unreadable — treat as "no existing credential", write fresh.
}

const unchanged =
  existing &&
  existing.access_token === candidate.access_token &&
  existing.refresh_token === candidate.refresh_token &&
  existing.expires_at === candidate.expires_at;

if (unchanged) {
  console.log("OpenClaw credential unchanged since last sync — nothing to do.");
  process.exit(0);
}

fs.mkdirSync(authDir, { recursive: true });
// Write-to-temp-then-rename: rename() is atomic on POSIX (same filesystem),
// so a concurrent reader of auth.json never observes a partially-written file.
const tmp = path.join(authDir, `auth.json.tmp-${process.pid}-${Date.now()}`);
fs.writeFileSync(tmp, JSON.stringify(candidate, null, 2), { mode: 0o600 });
fs.renameSync(tmp, authFile);

console.log(existing ? "Synced updated OpenAI OAuth credential from OpenClaw." : "Imported OpenAI OAuth credential from OpenClaw.");
console.log("Account ID:", cred.accountId);
const minsLeft = Math.round((cred.expires - Date.now()) / 60000);
console.log("Access token valid for another", minsLeft, "min.");
' "$raw_json" "$AUTH_DIR"
