# chatgpt-codex-auth.ts

Call OpenAI models using a ChatGPT Plus/Pro **subscription** instead of an
OpenAI API key. One file, zero dependencies, copy-paste into any Node.js
18+ TypeScript project.

The file to copy is
[`chatgpt-codex-auth.ts`](chatgpt-codex-auth.ts) — everything else in this
folder (`package.json`, `try.ts`, `try-image.ts`) is a dev harness used to
verify that file, not part of what you copy.

## Setup

1. Copy `chatgpt-codex-auth.ts` into your project.
2. Sign in once (opens a browser for OAuth):

```ts
import { login } from "./chatgpt-codex-auth.js";
await login();
```

This writes a token to `~/.open-ai-sub-auth/auth.json` — shared across any
project on this machine using this file (or any other `open-ai-sub-auth`
package), so you generally only do this once per machine, not once per
project. Needs an active ChatGPT Plus or Pro subscription, no API key.

## Usage

```ts
import { chat } from "./chatgpt-codex-auth.js";

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
import { chat, imageFromFile } from "./chatgpt-codex-auth.js";

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

`chat()` calls `getValidAuth()` internally — no need to call it yourself
unless you want to check/refresh a token without sending a message.

## Things to know

- **Model drift**: OpenAI renames Codex-backend model ids over time. If
  `chat()` starts failing with a "model is not supported" error, that's
  very likely a stale model id — pass a current `model` in `opts`.
- **No API key anywhere.** All network calls go to `auth.openai.com` and
  `chatgpt.com` only.
- **ToS note**: using ChatGPT subscription auth for programmatic access
  outside the official Codex CLI sits in a gray area of OpenAI's terms,
  though OpenAI has opened this up for third-party tools like OpenClaw.
