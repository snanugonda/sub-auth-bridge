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

`PORT` env var overrides the default `8787`.
