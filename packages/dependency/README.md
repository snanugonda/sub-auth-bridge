# @open-ai-sub-auth/dependency

Call OpenAI models using a ChatGPT Plus/Pro **subscription** instead of an
OpenAI API key. Authenticates via OAuth (same mechanism as the official
Codex CLI and OpenClaw), then talks to the ChatGPT Codex backend. Import
`login()` and `chat()` as normal functions — no separate CLI or service to
run.

Not published to npm (`"private": true` in `package.json`). Install it
directly from this repo:

```bash
npm install /absolute/path/to/open-ai-sub-auth/packages/dependency
# or, from a git checkout:
npm install github:<owner>/open-ai-sub-auth#path:packages/dependency
```

Requires Node.js 18+.

## Prerequisite: sign in once

A local-path install doesn't automatically install this package's own
`devDependencies`, so run login from the actual repo checkout, not through
`node_modules`:

```bash
cd /path/to/open-ai-sub-auth/packages/dependency
npm install
npm run login
```

This opens a browser for a one-time OAuth flow and writes a token to
`~/.open-ai-sub-auth/auth.json` — shared by any project on this machine
that uses this package, so you only do this once per machine. Needs an
active ChatGPT Plus or Pro subscription, nothing else to configure, no API
key.

## Usage

```ts
import { chat } from "@open-ai-sub-auth/dependency";

const reply = await chat([{ role: "user", content: "Say hello in one sentence." }]);
console.log(reply);
```

Streaming:

```ts
await chat([{ role: "user", content: "Write a haiku." }], {
  onDelta: (text) => process.stdout.write(text),
});
```

Images and files:

```ts
import { chat, imageFromFile } from "@open-ai-sub-auth/dependency";

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

## API

```ts
function login(): Promise<StoredAuth>;
function getValidAuth(): Promise<StoredAuth>;
function loadAuth(): StoredAuth | null;

function chat(messages: ChatMessage[], opts?: ChatOptions): Promise<string>;
function imageFromFile(path: string): ContentPart;
function fileFromFile(path: string): ContentPart;

type ChatMessage = { role: "user" | "assistant" | "system"; content: string | ContentPart[] };
type ContentPart =
  | { type: "text"; text: string }
  | { type: "image"; dataUrl: string }
  | { type: "file"; dataUrl: string; filename: string };
type ChatOptions = { model?: string; instructions?: string; onDelta?: (text: string) => void };
```

`chat()` calls `getValidAuth()` internally — you don't need to call it
yourself unless you want to check/refresh a token without sending a
message.

## Things to know

- **Token storage**: `~/.open-ai-sub-auth/auth.json`, `0600` permissions.
  Shared with any other `open-ai-sub-auth` package on the same machine —
  sign in once, all of them pick it up.
- **Model drift**: OpenAI renames Codex-backend model ids over time. If
  `chat()` starts failing with a "model is not supported" error, that's
  very likely a stale model id, not an auth problem — pass a current
  `model` explicitly in `opts` if the built-in default has gone stale.
- **No API key anywhere.** All network calls go to `auth.openai.com` and
  `chatgpt.com` only.
- **ToS note**: using ChatGPT subscription auth for programmatic access
  outside the official Codex CLI sits in a gray area of OpenAI's terms,
  though OpenAI has opened this up for third-party tools like OpenClaw.
