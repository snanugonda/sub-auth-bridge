# @open-ai-sub-auth/single-file

The deliverable is `chatgpt-codex-auth.ts` — one flat file, copy-paste into
any Node 18+ TS project, zero deps. Everything else here (`package.json`,
`try.ts`) is a dev harness to verify it typechecks and runs; not meant to be
shipped. See root `CLAUDE.md` for shared gotchas.

## Commands

```bash
npm run typecheck
npm run try -- "prompt here"   # exercises chat() through the real file
npm run try-image -- /path/to/image.png   # exercises imageFromFile() + chat()
```

If you edit `chatgpt-codex-auth.ts`, this is intentionally NOT synced with
`packages/dependency` or `packages/service` — the three packages are
standalone by design, fix the same bug in each if it applies to all three.
