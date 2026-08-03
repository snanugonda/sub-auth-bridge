import { randomUUID } from "node:crypto";
import { CODEX_RESPONSES_URL, OPENAI_HEADERS, OPENAI_HEADER_VALUES } from "./constants.js";
import { getValidAuth } from "./auth.js";

export interface ChatMessage {
  role: "user" | "assistant" | "system";
  content: string;
}

export interface ChatOptions {
  model?: string;
  instructions?: string;
  onDelta?: (text: string) => void;
}

// The Codex backend speaks the Responses API shape, not /v1/chat/completions.
function toResponsesInput(messages: ChatMessage[]) {
  return messages.map((m) => ({
    role: m.role,
    content: [{ type: m.role === "assistant" ? "output_text" : "input_text", text: m.content }],
  }));
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
