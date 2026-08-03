# @open-ai-sub-auth/dependency

Import-as-dependency version. Export surface is `src/index.ts`
(`login`, `getValidAuth`, `loadAuth`, `chat`). See root `CLAUDE.md` for
shared gotchas (store:false, model drift, token file).

## Commands

```bash
npm run login   # one-time browser OAuth (PKCE)
npm run chat -- "prompt here"   # stream a completion via CLI
npm run build    # tsc emit to dist/ (what "main"/"types" in package.json point to)
```

## Architecture

- `src/constants.ts` — OAuth client_id, endpoints, headers.
- `src/pkce.ts` — PKCE verifier/challenge generation.
- `src/auth.ts` — login flow (local callback server on :1455), token
  store/refresh, JWT decode for `chatgpt_account_id`.
- `src/client.ts` — calls `chatgpt.com/backend-api/codex/responses` (the
  Responses API shape, NOT `/v1/chat/completions`), parses SSE deltas.
- `src/index.ts` — the actual public API when imported as a dependency.
- `src/cli-login.ts`, `src/example.ts` — CLI entry points only, not exported.
