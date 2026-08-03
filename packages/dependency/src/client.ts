import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { extname, basename } from "node:path";
import { CODEX_RESPONSES_URL, OPENAI_HEADERS, OPENAI_HEADER_VALUES } from "./constants.js";
import { getValidAuth } from "./auth.js";

/** One piece of a multimodal message. Build image/file parts with {@link imageFromFile}/{@link fileFromFile}. */
export type ContentPart =
  | { type: "text"; text: string }
  | { type: "image"; dataUrl: string }
  | { type: "file"; dataUrl: string; filename: string };

/** A single turn in a {@link chat} call. `content` can be plain text or a mix of text/image/file parts. */
export interface ChatMessage {
  role: "user" | "assistant" | "system";
  content: string | ContentPart[];
}

export interface ChatOptions {
  /** Overrides the built-in default model id. Codex-backend model ids drift over time. */
  model?: string;
  /** Overrides the default system instructions ("You are a helpful assistant."). */
  instructions?: string;
  /** Called with each streamed text chunk as it arrives, in addition to the full text being returned at the end. */
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

function fileToDataUrl(path: string): { dataUrl: string; mime: string } {
  const mime = MIME_TYPES[extname(path).toLowerCase()] ?? "application/octet-stream";
  const b64 = readFileSync(path).toString("base64");
  return { dataUrl: `data:${mime};base64,${b64}`, mime };
}

/**
 * Reads a local image file (png/jpg/jpeg/gif/webp) and base64-encodes it
 * into a {@link ContentPart} usable in a {@link chat} message's `content` array.
 */
export function imageFromFile(path: string): ContentPart {
  return { type: "image", dataUrl: fileToDataUrl(path).dataUrl };
}

/**
 * Reads a local file (e.g. PDF) and base64-encodes it into a
 * {@link ContentPart} usable in a {@link chat} message's `content` array.
 */
export function fileFromFile(path: string): ContentPart {
  return { type: "file", dataUrl: fileToDataUrl(path).dataUrl, filename: basename(path) };
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

/**
 * Sends a chat completion request to the ChatGPT Codex backend using
 * subscription auth (calls {@link getValidAuth} internally — sign in with
 * `login()` first). Always streams under the hood; resolves with the full
 * text once the response completes. Pass `opts.onDelta` to also react to
 * each chunk as it arrives.
 */
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
