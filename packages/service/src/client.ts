import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { extname, basename } from "node:path";
import { CODEX_RESPONSES_URL, OPENAI_HEADERS, OPENAI_HEADER_VALUES } from "./constants.js";
import { getValidAuth } from "./auth.js";

export type ContentPart =
  | { type: "text"; text: string }
  | { type: "image"; dataUrl: string }
  | { type: "file"; dataUrl: string; filename: string };

export interface ChatMessage {
  role: "user" | "assistant" | "system";
  content: string | ContentPart[];
}

export interface ChatOptions {
  model?: string;
  instructions?: string;
  onDelta?: (text: string) => void;
}

const MIME_TYPES: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".pdf": "application/pdf",
};

function fileToDataUrl(path: string): string {
  const mime = MIME_TYPES[extname(path).toLowerCase()] ?? "application/octet-stream";
  const b64 = readFileSync(path).toString("base64");
  return `data:${mime};base64,${b64}`;
}

/** Reads a local image file (on the server's disk) and builds an image content part. */
export function imageFromFile(path: string): ContentPart {
  return { type: "image", dataUrl: fileToDataUrl(path) };
}

/** Reads a local file (e.g. PDF, on the server's disk) and builds a file content part. */
export function fileFromFile(path: string): ContentPart {
  return { type: "file", dataUrl: fileToDataUrl(path), filename: basename(path) };
}

// The Codex backend speaks the Responses API shape, not /v1/chat/completions.
function toResponsesInput(messages: ChatMessage[]) {
  return messages.map((m) => {
    const textType = m.role === "assistant" ? "output_text" : "input_text";
    if (typeof m.content === "string") {
      return { role: m.role, content: [{ type: textType, text: m.content }] };
    }
    return {
      role: m.role,
      content: m.content.map((part) => {
        if (part.type === "image") return { type: "input_image", image_url: part.dataUrl };
        if (part.type === "file")
          return { type: "input_file", filename: part.filename, file_data: part.dataUrl };
        return { type: textType, text: part.text };
      }),
    };
  });
}

/** Streams a completion from the ChatGPT Codex backend using subscription auth. */
export async function chat(messages: ChatMessage[], opts: ChatOptions = {}): Promise<string> {
  const auth = await getValidAuth();
  const sessionId = randomUUID();

  const res = await fetch(CODEX_RESPONSES_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "text/event-stream",
      Authorization: `Bearer ${auth.access_token}`,
      [OPENAI_HEADERS.ACCOUNT_ID]: auth.account_id,
      [OPENAI_HEADERS.BETA]: OPENAI_HEADER_VALUES.BETA_RESPONSES,
      [OPENAI_HEADERS.ORIGINATOR]: OPENAI_HEADER_VALUES.ORIGINATOR_CODEX,
      session_id: sessionId,
    },
    body: JSON.stringify({
      model: opts.model ?? "gpt-5.6-sol",
      instructions: opts.instructions ?? "You are a helpful assistant.",
      input: toResponsesInput(messages),
      stream: true,
      store: false, // Codex backend requires stateless requests
    }),
  });

  if (!res.ok || !res.body) {
    throw new Error(`Codex request failed: ${res.status} ${await res.text()}`);
  }

  let full = "";
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";

    for (const line of lines) {
      if (!line.startsWith("data: ")) continue;
      const data = line.slice("data: ".length).trim();
      if (data === "[DONE]") continue;

      const event = JSON.parse(data);
      if (event.type === "response.output_text.delta" && typeof event.delta === "string") {
        full += event.delta;
        opts.onDelta?.(event.delta);
      }
    }
  }

  return full;
}
