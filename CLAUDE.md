# open-ai-sub-auth (workspace)

Monorepo of 3 **standalone** implementations of the same thing: ChatGPT
subscription OAuth (PKCE) + Codex backend calls. No shared code between
packages by design — see `README.md` for which package is which.

## Multimodal input

All 3 packages support `content: string | ContentPart[]` on `ChatMessage`,
where `ContentPart` is `{type:"text",text}` / `{type:"image",dataUrl}` /
`{type:"file",dataUrl,filename}` (maps to Responses API `input_text` /
`input_image` / `input_file`). Each package also exports `imageFromFile(path)`
and `fileFromFile(path)` helpers that read a local file and base64-encode it
into the right shape. Verified working (OCR'd text out of a PNG) in all 3.

## Shared gotchas (apply to all 3 packages)

- **`store: false` is mandatory** in the Codex request body. Omitting it (or
  `store: true`) makes the backend reject with a misleading
  `"model X is not supported when using Codex with a ChatGPT account"` 400 —
  looks like a model-name problem, isn't.
- **Model IDs drift.** OpenAI renames Codex-backend model ids often (seen:
  `gpt-5.1-codex` → current default `gpt-5.6-sol`). If chat suddenly 400s
  with the same "not supported" message, check OpenClaw's
  `extensions/openai/default-models.ts` (`OPENAI_CODEX_DEFAULT_MODEL`) on
  GitHub for the current value, not old docs/memory.
- Token file: `~/.open-ai-sub-auth/auth.json`, mode `0600`, shared across all
  3 packages. Independent-login credentials (no `source` field) auto-refresh
  minutes before expiry, guarded by a cross-process lockfile (`auth.lock` in
  the same dir) so two processes sharing this file never both call OpenAI's
  refresh endpoint at once — OpenAI's refresh tokens are single-use/rotating,
  so a double-refresh would strand one caller with an already-invalidated
  token. Writes go through temp-file + `rename()` so a concurrent reader
  never sees a partial file. Credentials tagged `source: "openclaw"` are
  never refreshed by any of the 3 packages at all — see next section.
- All outbound calls go to `auth.openai.com` and `chatgpt.com` only. `CLIENT_ID`
  (`app_EMoamEEZ73f0CkXaXp7hrann`) is OpenAI's own *public* Codex CLI OAuth
  client id — not a secret, safe to see hardcoded in all 3 packages.

## Cloning to a new machine

`./scripts/repo.sh setup` handles the whole first-run flow: installs deps,
asks whether to import an OpenClaw login or do a fresh one (only if
`~/.open-ai-sub-auth/auth.json` doesn't already exist), starts the service,
health-checks it, sends a test chat message. `./scripts/repo.sh teardown`
reverses the service side of it (stop, remove docker image, clear
`.repo-state`) without ever touching `auth.json`, OpenClaw, or anything else
on the host.

OpenClaw import (`scripts/import-openclaw-auth.sh`, also reachable as
`./scripts/repo.sh login openclaw`) reads OpenClaw's own SQLite store
read-only (`~/.openclaw/agents/main/agent/openclaw-agent.sqlite`, table
`auth_profile_store`, row `store_key='primary'`) and writes this repo's
`auth.json` in this repo's own shape, tagged `source: "openclaw"`. This
depends on OpenClaw's internal, undocumented schema, so it can break on a
future OpenClaw release — but it has been verified against a real
production OpenClaw database (not just a synthetic mock): imported the real
`openai:default` credential, confirmed the `account_id` matched the account
already in use, then made a live chat call with the imported token and got
a real response back. If it ever fails or OpenClaw changes its storage
format, the fallback is always `./scripts/repo.sh login` (fresh OAuth,
~30 seconds, same account, zero dependency on OpenClaw's internals).

**Why this repo never refreshes an OpenClaw-sourced credential itself**:
OpenAI's refresh tokens are single-use/rotating (inferred from OpenClaw's
own `refresh_token_reused` error-handling code). If this repo called
refresh on a token copied from OpenClaw, it would silently invalidate
OpenClaw's own live session the moment it did. So `getValidAuth()` in all 3
packages checks `source === "openclaw"` and, if expired, throws instead of
refreshing — it only ever gets a fresh token by re-running the import
script, which only ever reads (never writes to, never refreshes) OpenClaw's
store. This has been fully tested live against synthetic and real data:
expired-and-tagged credentials fail fast with zero network calls; the
import script correctly imports, skips writing when unchanged (proven via
unchanged mtime), and syncs-and-writes when OpenClaw's copy changes.

**Auto-sync (`./scripts/repo.sh enable-auto-sync`)**: registers the import
script with launchd (macOS) or cron (Linux) to run every 60s by default, so
an OpenClaw-linked `auth.json` practically never goes stale. Purely local —
the sync itself never talks to OpenAI, only OpenClaw's own refreshes
(happening on its own schedule, independent of this) do, so running this
often costs nothing on OpenAI's side. **Not installed by `setup`** — opt-in
only. **Live-verified** (user ran it directly — an agent can't: registering
a launchd/cron job needs a real permission grant, blocked here even after
in-chat approval). First real run caught a genuine bug: launchd/cron run
jobs with a minimal system PATH, not the interactive shell's, so `node`
wasn't found even though it works in a normal terminal. Fixed by resolving
`node`'s directory in the enabling shell and baking it into the job's own
environment (`EnvironmentVariables`/`PATH` in the plist; inline `PATH=` on
the cron line).

To actually verify this on a real machine: `./scripts/repo.sh
verify-auto-sync` — run it yourself, not via an agent (registering a
launchd/cron job is a host-level permission grant). It enables auto-sync,
then *waits for a real scheduler tick* (polls the sync log's mtime for up
to 150s — proof something actually ran, not just that it's registered),
classifies the result (PASS / FAIL / INCONCLUSIVE, e.g. "no OpenClaw db on
this machine" is a pass for the scheduler but inconclusive for real sync
content), and writes a timestamped report to
`.repo-state/verify-auto-sync-<UTC timestamp>.txt`. Its polling/
classification logic was verified in isolation (mocked log writes,
covering all three verdict paths) since the actual `enable-auto-sync` call
can't be run by an agent in this environment — the final live integration
still needs a real run.

For anything else, `./scripts/repo.sh debug-bundle` writes one timestamped
file (`.repo-state/diagnostics-<UTC timestamp>.txt`) containing doctor
output, auto-sync status, service status, the last 200 lines of the sync
log, the last 100 lines of the node-mode service log, and redacted
`auth.json` metadata (`source` + expiry only — never tokens, never
`access`/`refresh` values). Both are safe to share as-is, no manual
redaction needed.

## Dev quirks (this environment)

- `tsx -e "..."` / `node -e "..."` fail on top-level `await` (esbuild cjs
  error) — write a scratch `.ts` file and `npx tsx file.ts` instead.
- Bash tool cwd can silently reset to repo root between calls — `cd`
  explicitly (or use absolute paths) per command, don't assume a prior `cd`
  persisted.
- Attached image files under `~/.claude/image-cache/...` are
  session-temporary and can vanish by a later turn — for repeatable
  image/OCR tests, generate one with
  `python3 -c "from PIL import Image, ImageDraw; ..."` instead of relying on
  it still being there.
- A process running inside a Docker container **cannot know its own
  host-mapped port** from `process.env.PORT` — that env var (if set at all
  inside the container) is always the fixed *internal* container port, not
  whatever host port Docker/the OS assigned it (`-p 127.0.0.1::8787`
  ephemeral mapping). Learned this building the OpenAPI `servers.url` field
  in `packages/service`: patching it from `PORT` at startup silently
  produced a wrong, unreachable URL once `repo.sh` started assigning host
  ports dynamically. Fix was deriving the URL from the incoming request's
  `Host` header instead — always correct, works identically in node mode,
  Docker, and behind any future reverse proxy.
- `repo.sh` runs under macOS's default `/bin/bash` — **bash 3.2** (Apple
  froze it there for licensing reasons, never shipped 4+). Under `set -u`,
  `"${array[@]}"` on a zero-element array throws "unbound variable" in 3.2,
  even though the exact same code works fine on bash 4+/5 (e.g. Linux CI,
  Homebrew bash). Use the bash-3.2-safe idiom instead:
  `${array[@]+"${array[@]}"}`. Bit `scripts/repo.sh`'s Docker network args
  — worked in isolated syntax checks, only broke on the actual empty-array
  case (`DOCKER_NETWORK` unset).
- launchd and cron both run scheduled jobs with a **minimal system PATH**
  (`/usr/bin:/bin:/usr/sbin:/sbin`), not the interactive shell's — a binary
  that resolves fine in a terminal (`node` via Homebrew/nvm/etc.) can be
  "command not found" when the same script runs on a schedule. Resolve the
  real path (`command -v node`) in the shell that's registering the job,
  bake it into the job's own environment — don't trust the default PATH.
- When testing git-integrated script behavior (e.g. `update`'s `--ff-only`
  guard) with throwaway local commits, don't use `git commit -am` — it
  sweeps up *all* modified files, including real uncommitted work, into
  the test commit. Stage/stash explicitly, or use a scratch branch.

## Reference sources

Auth flow + request shape cross-verified against OpenAI's own `openai/codex`
(official, MIT) and OpenClaw's `extensions/openai/` +
`packages/ai/src/providers/openai-chatgpt-responses.ts` (OpenClaw is the
user's own daily driver — confirmed working there before this was built).
