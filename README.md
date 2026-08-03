# open-ai-sub-auth

Use a ChatGPT Plus/Pro **subscription** to call OpenAI's models from your own
TypeScript code — no OpenAI API key, no per-token billing. This authenticates
the same way the official Codex CLI and [OpenClaw](https://github.com/openclaw/openclaw)
do: OAuth 2.0 with PKCE against `auth.openai.com`, then requests against the
ChatGPT Codex backend (`chatgpt.com/backend-api/codex/responses`).

This is a personal/experimental project, not an official OpenAI SDK.

## Maintenance script

`./scripts/repo.sh` wraps every command below — install, build, login,
start/stop the service (Docker or plain Node), status, doctor, logs, chat,
clean. Run `./scripts/repo.sh help` for the full list. This is the
recommended way to operate the repo instead of running package-level npm
commands by hand.

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
4. **Refresh** — the access token is refreshed automatically via the stored
   refresh token, a few seconds before it expires. You only need to log in
   again if the refresh token itself is revoked (e.g. you signed out of
   ChatGPT elsewhere).

All network traffic goes to exactly two OpenAI-owned domains:
`auth.openai.com` and `chatgpt.com`. Nothing else, no third parties. The
OAuth `client_id` embedded in the code (`app_EMoamEEZ73f0CkXaXp7hrann`) is
OpenAI's own public Codex CLI client id — it's meant to be public, not a
secret, the same way GitHub CLI's or `gcloud`'s OAuth client ids are public.

## Repo layout

Three standalone implementations of the same thing. They intentionally
**don't share code** — pick the one that fits, use it on its own.

| Package | What it is | Use case |
|---|---|---|
| [`packages/dependency`](packages/dependency) | Installable npm-style module (`main`/`types`/`exports`) | Import `login()` / `chat()` as normal function calls in a TS/Node project |
| [`packages/single-file`](packages/single-file) | One flat `.ts` file, zero dependencies | Copy-paste into any existing project |
| [`packages/service`](packages/service) | HTTP API (`node:http`, no framework) + Dockerfile | A backend any language/service can call over HTTP |

All three read and write the same `~/.open-ai-sub-auth/auth.json` — sign in
once with any one of them, the other two pick up the same session
automatically.

## Prerequisites

- Node.js 18+
- An active ChatGPT **Plus** or **Pro** subscription (this is what's billed —
  there's no OpenAI API key involved anywhere)
- Docker, only if you want to run `packages/service` containerized

## Quick start

Pick any package and log in once:

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

## Running the service in Docker

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
docker build -t open-ai-sub-auth-service .
docker run -d -p 8787:8787 \
  -v "$HOME/.open-ai-sub-auth:/data/auth" \
  -e OPEN_AI_SUB_AUTH_DIR=/data/auth \
  open-ai-sub-auth-service
```

See [`packages/service/CLAUDE.md`](packages/service/CLAUDE.md) for the full
route reference.

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
