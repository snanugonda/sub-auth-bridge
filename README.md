# open-ai-sub-auth

Use a ChatGPT Plus/Pro **subscription** to call OpenAI's models from your own
TypeScript code — no OpenAI API key, no per-token billing. This authenticates
the same way the official Codex CLI and [OpenClaw](https://github.com/openclaw/openclaw)
do: OAuth 2.0 with PKCE against `auth.openai.com`, then requests against the
ChatGPT Codex backend (`chatgpt.com/backend-api/codex/responses`).

This is a personal/experimental project, not an official OpenAI SDK.

## Maintenance script

`./scripts/repo.sh <command>` is the **recommended way to operate this
repo** — install, login, run the service, check status, debug, clean up.
Prefer it over running package-level `npm` commands by hand (those still
work, see [Manual setup](#manual-setup-without-reposh) below, but you lose
the OpenClaw-login prompt, health checks, and diagnostics bundling).

| Command | What it does |
|---|---|
| `setup` | First run: install, ask login mode (new vs. OpenClaw import), start the service, health-check, send a test chat |
| `install` | `npm install` in all 3 packages |
| `build` | Build/typecheck all 3 packages |
| `login [new\|openclaw]` | Run OAuth login, or import an existing OpenClaw login |
| `start [docker\|node]` | Start `packages/service` (auto-detects Docker if available); picks a free port automatically — see [Dynamic ports](#dynamic-ports) |
| `stop` | Stop the running service, however it was started |
| `restart [docker\|node]` | Stop then start |
| `status` | Auth status + service status + health check |
| `logs` | Tail service logs (Docker or local) |
| `chat "prompt"` | Send a chat message (via the running service, else falls back to `packages/dependency`) |
| `doctor` | Full environment health check |
| `teardown` | Stop + remove the service's Docker image + clear `.repo-state` (never touches OpenClaw or your `auth.json`) |
| `clean` | Remove `node_modules`/`dist` in all 3 packages |
| `enable-auto-sync` | Install a launchd (macOS) / cron (Linux) job that runs the OpenClaw sync every 60s — opt-in, not run by `setup` |
| `disable-auto-sync` | Remove that scheduled job |
| `auto-sync-status` | Check whether it's currently installed |
| `debug-bundle` | Write one timestamped diagnostics file (doctor + status + log tails + redacted auth metadata, never raw tokens) to share back for debugging |
| `help` | Print this list |

`./scripts/repo.sh help` prints the same list from the script itself if
this table ever drifts out of sync.

## How it works

1. **Login** — a one-time browser-based OAuth PKCE flow. A local server
   briefly listens on `http://localhost:1455/auth/callback` to catch the
   redirect, exchanges the authorization code for tokens, and decodes the
   returned `id_token` (JWT) to read your `chatgpt_account_id`.
2. **Storage** — tokens are written to `~/.open-ai-sub-auth/auth.json`
   (`0600` permissions, your user only).
3. **Calling the model** — requests go to the Codex backend using the
   [Responses API](https://platform.openai.com/docs/api-reference/responses)
   shape (not `/v1/chat/completions`), with your access token as a Bearer
   token plus a `chatgpt-account-id` header. `store: false` is required —
   the backend rejects otherwise.
4. **Refresh** — for an independent login, the access token refreshes
   automatically via the stored refresh token, guarded by a cross-process
   lock so two of our own processes sharing the same `auth.json` never
   refresh at once (OpenAI's refresh tokens are single-use — a double
   refresh would strand one caller with an already-invalid token). You only
   need to log in again if the refresh token itself is revoked. Credentials
   imported from OpenClaw (`source: "openclaw"` in `auth.json`) are handled
   differently — see [OpenClaw import](#importing-an-existing-openclaw-login) below.

All network traffic goes to exactly two OpenAI-owned domains:
`auth.openai.com` and `chatgpt.com`. Nothing else, no third parties. The
OAuth `client_id` embedded in the code (`app_EMoamEEZ73f0CkXaXp7hrann`) is
OpenAI's own public Codex CLI client id — it's meant to be public, not a
secret, the same way GitHub CLI's or `gcloud`'s OAuth client ids are public.

## Repo layout

Three standalone implementations of the same thing. They intentionally
**don't share code** — pick the one that fits, use it on its own.

| Package | What it is | Use case | Docs |
|---|---|---|---|
| [`packages/dependency`](packages/dependency) | Installable npm-style module (`main`/`types`/`exports`) | Import `login()` / `chat()` as normal function calls in a TS/Node project | [README](packages/dependency/README.md) |
| [`packages/single-file`](packages/single-file) | One flat `.ts` file, zero dependencies | Copy-paste into any existing project | [README](packages/single-file/README.md) |
| [`packages/service`](packages/service) | HTTP API (`node:http`, no framework) + Dockerfile | A backend any language/service can call over HTTP | [README](packages/service) · [OpenAPI spec](packages/service/openapi.json) (also served live at `GET /openapi.json`) |

`packages/dependency` and `packages/single-file` each have a standalone
`README.md` written to travel with the code itself (as an npm dependency,
or as a copy-pasted file) — point an AI agent working in a *different*
project at that file when it needs to know how to use this as a library.
`packages/service`'s `openapi.json` is the machine-readable equivalent for
the HTTP API — feed it directly to any tool/agent that consumes OpenAPI
specs, or have it fetch `GET /openapi.json` from a running instance.

All three read and write the same `~/.open-ai-sub-auth/auth.json` — sign in
once with any one of them, the other two pick up the same session
automatically.

## Prerequisites

- Node.js 18+
- An active ChatGPT **Plus** or **Pro** subscription (this is what's billed —
  there's no OpenAI API key involved anywhere)
- Docker, only if you want to run `packages/service` containerized

## Quick start

```bash
./scripts/repo.sh setup
```

Installs all 3 packages, prompts you to sign in (new OAuth login, or import
an existing OpenClaw session if one's found on the machine), starts
`packages/service`, health-checks it, and sends a real test chat message so
you know it actually works. That's the whole setup.

```bash
./scripts/repo.sh chat "Say hello in one sentence."
```

### Manual setup (without repo.sh)

If you'd rather work with one package directly instead of through
`repo.sh` — e.g. you only want `packages/dependency` as a code dependency,
not the service:

```bash
cd packages/dependency   # or packages/single-file, or packages/service
npm install
npm run login             # opens a browser, sign in with ChatGPT
```

Then, depending on the package:

```bash
# packages/dependency or packages/single-file
npm run chat -- "Say hello in one sentence."

# packages/service
npm run dev               # starts the HTTP API on :8787
curl localhost:8787/api/chat -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hello in one sentence."}]}'
```

## Multimodal input (text, images, files)

All three packages accept either a plain string or a structured array for
`ChatMessage.content`:

```ts
type ContentPart =
  | { type: "text"; text: string }
  | { type: "image"; dataUrl: string }
  | { type: "file"; dataUrl: string; filename: string };
```

`imageFromFile(path)` and `fileFromFile(path)` (exported by
`packages/dependency` and `packages/single-file`) read a local file and
base64-encode it into the right shape:

```ts
import { chat, imageFromFile } from "./chatgpt-codex-auth.js"; // or the dependency package

const text = await chat([
  {
    role: "user",
    content: [
      { type: "text", text: "What text is in this image?" },
      imageFromFile("./screenshot.png"),
    ],
  },
]);
```

`packages/service` accepts the same `ContentPart[]` shape over HTTP — the
caller base64-encodes and sends a `dataUrl` directly in the JSON body (its
`imageFromFile`/`fileFromFile` helpers exist too, but only make sense if
you're reading a file already on the server's own disk).

## Dynamic ports

`./scripts/repo.sh start` (and `setup`) doesn't assume port `8787` is
free — a common problem on machines running lots of Docker containers.
Unless you set `PORT=` yourself, it picks a free port automatically:
Docker's own ephemeral-port allocator in Docker mode (`docker run -p
127.0.0.1::8787`, then `docker port` to learn what got assigned), or a
quick free-port probe in node mode.

The chosen port is written to `.repo-state/service-port` and read back by
`status`, `chat`, `logs`, `stop`, and `debug-bundle` — you don't need to
track it yourself:

```bash
./scripts/repo.sh start
./scripts/repo.sh status   # shows the actual port it landed on
./scripts/repo.sh chat "hi"   # finds it automatically, no need to pass a URL
```

`GET /openapi.json`'s `servers[0].url` reflects the port you actually
connected through (derived from the request's `Host` header, not a
baked-in value) — safe to fetch from a running instance regardless of
which port it ended up on.

Set `PORT=` explicitly if you want a fixed, predictable port instead
(`PORT=8787 ./scripts/repo.sh start`) — that's treated as a hard
requirement and fails loudly if it's already taken, rather than silently
picking a different one.

## Running the service in Docker

This section is the manual/direct path (fixed port `8787:8787`). If you're
using `./scripts/repo.sh start docker` (or `setup`) instead, it picks a
free host port automatically unless you set `PORT=` yourself — see
[Dynamic ports](#dynamic-ports) below for how to find out which port it
picked.

> **Prerequisite: log in on the host before starting the container.**
> The OAuth flow needs a real browser and a local callback server on
> `localhost:1455` — neither works inside a container. Skip this and the
> container has no credentials to serve.
>
> ```bash
> cd packages/service
> npm install
> npm run login
> ```

Once that's done:

```bash
cd packages/service
docker compose up --build        # or: docker build + docker run, see below
```

The container only gets `~/.open-ai-sub-auth` bind-mounted in (read-write,
so token refresh persists back to the host) — not your whole home directory.

```bash
docker build -t hub .
docker run -d --name hub -p 8787:8787 \
  -v "$HOME/.open-ai-sub-auth:/data/auth" \
  -e OPEN_AI_SUB_AUTH_DIR=/data/auth \
  hub
```

The container/image is named `hub` — deliberately generic, not
`open-ai-...`, since outward-facing names in this project don't reveal the
backend. See [`packages/service/CLAUDE.md`](packages/service/CLAUDE.md) for
the full route reference, and for how another container can reach `hub` by
name instead of a host port (`DOCKER_NETWORK=<name> ./scripts/repo.sh start
docker`).

## Importing an existing OpenClaw login

If a machine already has [OpenClaw](https://github.com/openclaw/openclaw)
signed in with ChatGPT, you don't have to log in again separately:

```bash
./scripts/repo.sh login openclaw
```

This reads OpenClaw's own local credential store (read-only, never writes
to it) and mirrors it into this repo's `auth.json`, tagged
`source: "openclaw"`. Credentials tagged this way are **never refreshed by
this repo** — OpenAI's refresh tokens are single-use, so refreshing an
OpenClaw-derived token here would silently invalidate OpenClaw's own live
session. Instead, this repo only ever re-syncs (read-only) from OpenClaw's
current state.

To keep that sync current automatically instead of re-running it by hand:

```bash
./scripts/repo.sh enable-auto-sync    # launchd (macOS) / cron (Linux), opt-in only
./scripts/repo.sh auto-sync-status    # check it's registered
./scripts/repo.sh disable-auto-sync   # remove it
```

Not installed by `setup` — you opt in explicitly. It runs
`scripts/import-openclaw-auth.sh` every 60s; that script only ever reads
OpenClaw's database and skips writing entirely when nothing's changed, so
running it often is cheap and doesn't touch OpenAI at all (only OpenClaw's
own refreshes, on its own schedule, ever call OpenAI).

### Working across machines

The typical loop when developing this against a machine you're not
directly working on (e.g. testing `enable-auto-sync` on a host that already
runs OpenClaw):

```
pull latest → ./scripts/repo.sh setup (or just enable-auto-sync)
            → let it run
            → ./scripts/repo.sh debug-bundle
            → share the resulting .repo-state/diagnostics-<timestamp>.txt file
            → (fixes land, get pushed)
            → repeat from "pull latest"
```

`debug-bundle` is the only manual step — it bundles doctor output,
service/auto-sync status, log tails, and redacted `auth.json` metadata
(expiry/source only, never tokens) into one timestamped file that's safe to
send as-is.

## Things worth knowing

- **Model IDs drift.** OpenAI renames Codex-backend model ids over time
  (seen so far: `gpt-5.1-codex` → current default `gpt-5.6-sol`). If chat
  requests start failing with `"model X is not supported when using Codex
  with a ChatGPT account"`, that's very likely a stale model id, not an auth
  problem — check OpenClaw's `extensions/openai/default-models.ts` on GitHub
  for the current value.
- **ToS gray area.** Using ChatGPT subscription auth for programmatic access
  outside the official Codex CLI sits in a gray area of OpenAI's terms,
  though OpenAI has recently opened this up for third-party tools like
  OpenClaw. Know that going in.
- Each package's own `CLAUDE.md` has package-specific commands and gotchas;
  the root [`CLAUDE.md`](CLAUDE.md) has what's shared across all three.
