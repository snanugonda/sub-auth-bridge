import http from "node:http";
import { login, loadAuth } from "./auth.js";
import { chat, type ChatMessage } from "./client.js";

const PORT = Number(process.env.PORT ?? 8787);

function sendJson(res: http.ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(payload);
}

async function readJsonBody<T>(req: http.IncomingMessage): Promise<T> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const raw = Buffer.concat(chunks).toString("utf-8");
  return raw ? JSON.parse(raw) : ({} as T);
}

async function handleLogin(_req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
  try {
    const auth = await login();
    sendJson(res, 200, { signedIn: true, accountId: auth.account_id });
  } catch (error) {
    sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) });
  }
}

function handleStatus(_req: http.IncomingMessage, res: http.ServerResponse): void {
  const auth = loadAuth();
  sendJson(res, 200, {
    signedIn: !!auth,
    accountId: auth?.account_id ?? null,
    expiresAt: auth?.expires_at ?? null,
  });
}

async function handleChat(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
  let body: { messages?: ChatMessage[]; model?: string; instructions?: string; stream?: boolean };
  try {
    body = await readJsonBody(req);
  } catch {
    sendJson(res, 400, { error: "Invalid JSON body" });
    return;
  }

  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    sendJson(res, 400, { error: "Body must include a non-empty 'messages' array" });
    return;
  }

  // SSE passthrough for streaming clients
  if (body.stream) {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });
    try {
      await chat(body.messages, {
        model: body.model,
        instructions: body.instructions,
        onDelta: (text) => res.write(`data: ${JSON.stringify({ delta: text })}\n\n`),
      });
      res.write("data: [DONE]\n\n");
    } catch (error) {
      res.write(`data: ${JSON.stringify({ error: error instanceof Error ? error.message : String(error) })}\n\n`);
    }
    res.end();
    return;
  }

  try {
    const text = await chat(body.messages, { model: body.model, instructions: body.instructions });
    sendJson(res, 200, { text });
  } catch (error) {
    sendJson(res, 502, { error: error instanceof Error ? error.message : String(error) });
  }
}

const IMG_INSTRUCTIONS =
  "You are a precise OCR engine. Output ONLY the literal text visible in the " +
  "image, exactly as it appears, character for character. Never add commentary, " +
  "labels, explanations, markdown, or surrounding quotes. If there is no text " +
  "in the image, output nothing at all.";

// Strips wrapping the model may add despite instructions (quotes, code fences).
function stripWrapping(text: string): string {
  let out = text.trim();
  const fence = /^```[a-zA-Z]*\n([\s\S]*)\n```$/.exec(out);
  if (fence) out = fence[1].trim();
  out = out.replace(/^["'`]+|["'`]+$/g, "").trim();
  return out;
}

async function handleImg(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
  let body: { image?: string; model?: string };
  try {
    body = await readJsonBody(req);
  } catch {
    res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" }).end("Invalid JSON body");
    return;
  }

  if (!body.image || typeof body.image !== "string") {
    res
      .writeHead(400, { "Content-Type": "text/plain; charset=utf-8" })
      .end("Body must include an 'image' field (data URL, e.g. \"data:image/png;base64,...\")");
    return;
  }

  try {
    const text = await chat(
      [
        {
          role: "user",
          content: [
            { type: "text", text: "What text is in this image? Reply with just the text." },
            { type: "image", dataUrl: body.image },
          ],
        },
      ],
      { model: body.model, instructions: IMG_INSTRUCTIONS },
    );
    res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
    res.end(stripWrapping(text));
  } catch (error) {
    res
      .writeHead(502, { "Content-Type": "text/plain; charset=utf-8" })
      .end(error instanceof Error ? error.message : String(error));
  }
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);

  if (req.method === "GET" && url.pathname === "/api/health") {
    sendJson(res, 200, { ok: true });
    return;
  }
  if (req.method === "GET" && url.pathname === "/api/status") {
    handleStatus(req, res);
    return;
  }
  if (req.method === "POST" && url.pathname === "/api/login") {
    void handleLogin(req, res);
    return;
  }
  if (req.method === "POST" && url.pathname === "/api/chat") {
    void handleChat(req, res);
    return;
  }
  if (req.method === "POST" && url.pathname === "/api/img") {
    void handleImg(req, res);
    return;
  }

  sendJson(res, 404, { error: "Not found" });
});

server.listen(PORT, () => {
  console.log(`open-ai-sub-auth service listening on http://localhost:${PORT}`);
});
