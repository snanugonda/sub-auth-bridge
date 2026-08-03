# open-ai-sub-auth

"Sign in with ChatGPT" (OAuth PKCE, subscription auth) — calls the Codex
backend using a ChatGPT Plus/Pro subscription instead of OpenAI API-key
billing. Mirrors what the official Codex CLI and OpenClaw do.

Three standalone versions of the same working implementation, each in its
own package. They don't share code on purpose — pick one, use it, don't wire
them together.

| Package | Use case |
|---|---|
| [`packages/dependency`](packages/dependency) | Import `login()`/`chat()` as normal function calls in a TS project |
| [`packages/single-file`](packages/single-file) | One flat `.ts` file, copy-paste into any existing project |
| [`packages/service`](packages/service) | Standalone HTTP API (`/api/login`, `/api/chat`, `/api/status`) any language can call |

All three share the same OAuth flow and hit the same two OpenAI-owned
domains (`auth.openai.com`, `chatgpt.com`) — see each package's own docs for
gotchas.

Auth tokens are stored once at `~/.open-ai-sub-auth/auth.json` — sign in
with any one package and the other two pick up the same session.
