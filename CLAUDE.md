# open-ai-sub-auth

TS client for "Sign in with ChatGPT" (OAuth subscription auth) — calls the
Codex backend using a ChatGPT Plus/Pro subscription instead of API-key billing.
Mirrors what the official Codex CLI and OpenClaw do.

## Commands

```bash
npm run login   # one-time browser OAuth (PKCE), saves ~/.open-ai-sub-auth/auth.json
npm run chat -- "prompt here"   # stream a completion
npm run build    # tsc typecheck/emit
```

## Architecture

- `src/constants.ts` — OAuth client_id, endpoints, headers. `CLIENT_ID` is
  OpenAI's own *public* Codex CLI client id (not a secret, safe to hardcode).
- `src/pkce.ts` — PKCE verifier/challenge generation.
- `src/auth.ts` — login flow (local callback server on :1455), token
  store/refresh, JWT decode for `chatgpt_account_id`.
- `src/client.ts` — calls `chatgpt.com/backend-api/codex/responses` (the
  Responses API shape, NOT `/v1/chat/completions`), parses SSE deltas.

## Gotchas

- **`store: false` is mandatory** in the request body. Omitting it (or
  `store: true`) makes the backend reject the model with a misleading
  `"model X is not supported when using Codex with a ChatGPT account"` 400 —
  looks like a model-name problem, isn't.
- **Model IDs drift.** OpenAI renames Codex-backend model ids often (seen:
  `gpt-5.1-codex` → current default `gpt-5.6-sol`). If chat suddenly 400s
  with the same "not supported" message, check OpenClaw's
  `extensions/openai/default-models.ts` (`OPENAI_CODEX_DEFAULT_MODEL`) on
  GitHub for the current value, not old docs/memory.
- Token file: `~/.open-ai-sub-auth/auth.json`, mode `0600`. Access token
  auto-refreshes ~10 days before expiry via `getValidAuth()`; only re-run
  `npm run login` if refresh itself fails (revoked session).
- All outbound calls go to `auth.openai.com` and `chatgpt.com` only —
  verified via grep before trusting any third-party reference code.

## Reference sources

Auth flow cross-verified against OpenAI's own `openai/codex` (official,
MIT) and OpenClaw's `extensions/openai/` + `packages/ai/src/providers/
openai-chatgpt-responses.ts` (confirmed working, user's own daily driver).
