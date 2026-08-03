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

  sendJson(res, 404, { error: "Not found" });
});

server.listen(PORT, () => {
  console.log(`open-ai-sub-auth service listening on http://localhost:${PORT}`);
});
