# @open-ai-sub-auth/service

HTTP API wrapping the same OAuth+Codex logic, plain `node:http` (no Express,
zero runtime deps). `src/auth.ts`, `src/client.ts`, `src/pkce.ts`,
`src/constants.ts` are standalone copies, not imports, from
`packages/dependency` — see root `CLAUDE.md` on why. Fix bugs in both places.

## Commands

```bash
npm run dev     # tsx watch, http://localhost:8787
npm run build && npm run start   # production
```

## Routes

- `GET /api/health` — liveness
- `GET /api/status` — `{ signedIn, accountId, expiresAt }` from the shared token file
- `POST /api/login` — runs the browser OAuth flow server-side (blocks until browser completes it)
- `POST /api/chat` — `{ messages, model?, instructions?, stream? }`. `stream: true` returns SSE (`data: {"delta": "..."}`), otherwise `{ text }`. Each message's `content` can be a string or a `ContentPart[]` (`text`/`image`/`file` — image/file parts need a `dataUrl`, i.e. the caller base64-encodes before sending over HTTP; `imageFromFile`/`fileFromFile` in `src/client.ts` are for server-side use only, not exposed over the wire).
- `POST /api/img` — `{ image: "data:image/png;base64,...", model? }`. Response
  body is **plain text, not JSON** — exactly the text found in the image, no
  wrapping. Uses a locked OCR system prompt (`IMG_INSTRUCTIONS` in
  `src/server.ts`) plus `stripWrapping()` to strip quotes/code-fences if the
  model adds them anyway. This is intentionally a separate route from
  `/api/chat`, not a flag on it — the contract (plain text, nothing else) is
  incompatible with `/api/chat`'s `{ text }` JSON envelope.

`PORT` env var overrides the default `8787` for what the process itself
binds to. `repo.sh start` doesn't rely on this default when running
standalone — see [dynamic ports](#dynamic-ports-repo-sh) below.

`GET /openapi.json` serves `openapi.json` (checked into this dir), parsed
once at startup but with `servers[0].url` **patched per-request from the
incoming `Host` header**, not from `PORT`. This matters: inside a Docker
container, `PORT` is always the fixed *internal* port (8787) — the process
has no way to know what *host* port Docker mapped it to, so deriving from
`PORT` silently produces a wrong, unreachable URL whenever host and
container ports differ (which is the normal case once `repo.sh` starts
assigning ports dynamically). `Host` is always correct because it's
literally the address the client used to connect. Content of the base spec
(routes/schemas) is otherwise static; keep it in sync with `src/server.ts`
by hand — validate with `npx @redocly/cli lint openapi.json` before
committing.

### Dynamic ports (repo.sh)

When started via `./scripts/repo.sh start` (not `npm run dev`/`docker run`
directly), the host port isn't fixed at 8787 unless `PORT` is set
explicitly — see the root README's
[Dynamic ports](../../README.md#dynamic-ports) section. `repo.sh` tracks
the chosen port in `.repo-state/service-port`; this package's own code has
no awareness of that file, it just binds whatever `PORT` env var it's
launched with (or `8787` if unset, for direct `npm run dev`/`docker run`
usage).

## Docker

```bash
docker compose up --build
# or manually:
docker build -t open-ai-sub-auth-service .
docker run -d -p 8787:8787 \
  -v "$HOME/.open-ai-sub-auth:/data/auth" \
  -e OPEN_AI_SUB_AUTH_DIR=/data/auth \
  open-ai-sub-auth-service
```

- **Login first, on the host**, before running the container — `npm run login`
  in any package (they all write to the same `~/.open-ai-sub-auth/auth.json`).
  `POST /api/login` inside the container binds `localhost:1455` and tries to
  spawn a browser, neither of which works in a container — don't use it there.
- Bind mount is **only** `~/.open-ai-sub-auth` → `/data/auth`, not the whole
  home dir. `OPEN_AI_SUB_AUTH_DIR` (in `src/auth.ts`) is what makes the mount
  path configurable instead of hardcoded to `homedir()`.
- Mount is read-write, not read-only — `getValidAuth()` refreshes the access
  token and writes it back to the same file; read-only would break refresh
  after ~10 days and the container would need a manual restart+relogin.
- `docker build` prints a `SecretsUsedInArgOrEnv` warning for
  `OPEN_AI_SUB_AUTH_DIR` — false positive (it's a directory path, not a
  secret), safe to ignore.
