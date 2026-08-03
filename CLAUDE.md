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
  3 packages. Access token auto-refreshes minutes before expiry; only re-run
  a login flow if refresh itself fails (revoked ChatGPT session).
- All outbound calls go to `auth.openai.com` and `chatgpt.com` only. `CLIENT_ID`
  (`app_EMoamEEZ73f0CkXaXp7hrann`) is OpenAI's own *public* Codex CLI OAuth
  client id — not a secret, safe to see hardcoded in all 3 packages.

## Reference sources

Auth flow + request shape cross-verified against OpenAI's own `openai/codex`
(official, MIT) and OpenClaw's `extensions/openai/` +
`packages/ai/src/providers/openai-chatgpt-responses.ts` (OpenClaw is the
user's own daily driver — confirmed working there before this was built).
