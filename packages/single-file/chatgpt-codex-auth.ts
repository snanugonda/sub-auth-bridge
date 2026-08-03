// chatgpt-codex-auth.ts
// Sign in with ChatGPT (OAuth PKCE) and call the Codex backend using a
// ChatGPT Plus/Pro subscription instead of OpenAI API-key billing.
// Copy-paste this single file into any Node.js TypeScript project.
// Requires: Node 18+, no external dependencies.
//
// Usage:
//   import { login, chat } from "./chatgpt-codex-auth.js";
//   await login();  // one-time, opens browser
//   const reply = await chat([{ role: "user", content: "hi" }]);

import http from "node:http";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { randomBytes, randomUUID, createHash } from "node:crypto";

// ============================================================================
// Constants
// ============================================================================

const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"; // OpenAI's public Codex CLI OAuth client id
const AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
const TOKEN_URL = "https://auth.openai.com/oauth/token";
const REDIRECT_PORT = 1455;
const REDIRECT_URI = `http://localhost:${REDIRECT_PORT}/auth/callback`;
const SCOPE = "openid profile email offline_access";
const CODEX_RESPONSES_URL = "https://chatgpt.com/backend-api/codex/responses";
const JWT_CLAIM_PATH = "https://api.openai.com/auth";
const DEFAULT_MODEL = "gpt-5.6-sol"; // drifts over time — see README note

const AUTH_DIR = join(homedir(), ".open-ai-sub-auth");
const AUTH_FILE = join(AUTH_DIR, "auth.json");

// ============================================================================
// Types
// ============================================================================

export interface StoredAuth {
  access_token: string;
  refresh_token: string;
  id_token: string;
  account_id: string;
  expires_at: number; // epoch ms
}

export interface ChatMessage {
  role: "user" | "assistant" | "system";
  content: string;
}

export interface ChatOptions {
  model?: string;
  instructions?: string;
  onDelta?: (text: string) => void;
}

// ============================================================================
// PKCE
// ============================================================================

function base64url(input: Buffer): string {
  return input.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function generatePKCE(): { verifier: string; challenge: string } {
  const verifier = base64url(randomBytes(32));
  const challenge = base64url(createHash("sha256").update(verifier).digest());
  return { verifier, challenge };
}

// ============================================================================
// Token storage
// ============================================================================

export function loadAuth(): StoredAuth | null {
  if (!existsSync(AUTH_FILE)) return null;
  return JSON.parse(readFileSync(AUTH_FILE, "utf-8"));
}

function saveAuth(auth: StoredAuth): void {
  mkdirSync(AUTH_DIR, { recursive: true });
  writeFileSync(AUTH_FILE, JSON.stringify(auth, null, 2), { mode: 0o600 });
}

// Decode without verifying signature — fine here since the token came
// straight back from OpenAI's token endpoint over TLS; we're only reading
// claims, not trusting this as a security boundary.
function decodeJWT(token: string): any {
  const payload = token.split(".")[1];
  return JSON.parse(Buffer.from(payload, "base64").toString("utf-8"));
}

function extractAccountId(idToken: string): string {
  const claims = decodeJWT(idToken);
  const accountId = claims?.[JWT_CLAIM_PATH]?.chatgpt_account_id;
  if (!accountId) throw new Error("id_token missing chatgpt_account_id claim");
  return accountId;
}

function openBrowser(url: string): void {
  const opener =
    process.platform === "darwin" ? "open" : process.platform === "win32" ? "start" : "xdg-open";
  try {
    spawn(opener, [url], { stdio: "ignore", detached: true }).unref();
  } catch {
    // caller still prints the URL as a fallback
  }
}

async function exchangeCode(
  code: string,
  verifier: string,
): Promise<{ access_token: string; refresh_token: string; id_token: string; expires_in: number }> {
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: CLIENT_ID,
      code,
      code_verifier: verifier,
      redirect_uri: REDIRECT_URI,
    }),
  });
  if (!res.ok) throw new Error(`token exchange failed: ${res.status} ${await res.text()}`);
  return res.json();
}

async function refreshTokens(
  refreshToken: string,
): Promise<{ access_token: string; refresh_token: string; id_token: string; expires_in: number }> {
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      client_id: CLIENT_ID,
      refresh_token: refreshToken,
    }),
  });
  if (!res.ok) throw new Error(`token refresh failed: ${res.status} ${await res.text()}`);
  return res.json();
}

// ============================================================================
// Login
// ============================================================================

/** Runs the full browser-based PKCE login flow and persists credentials. */
export async function login(): Promise<StoredAuth> {
  const { verifier, challenge } = generatePKCE();
  const state = randomBytes(16).toString("hex");

  const url = new URL(AUTHORIZE_URL);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", CLIENT_ID);
  url.searchParams.set("redirect_uri", REDIRECT_URI);
  url.searchParams.set("scope", SCOPE);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", state);
  url.searchParams.set("id_token_add_organizations", "true");
  url.searchParams.set("codex_cli_simplified_flow", "true");
  url.searchParams.set("originator", "codex_cli_rs");

  const code = await new Promise<string>((resolve, reject) => {
    const server = http.createServer((req, res) => {
      const reqUrl = new URL(req.url ?? "", `http://localhost:${REDIRECT_PORT}`);
      if (reqUrl.pathname !== "/auth/callback") {
        res.writeHead(404).end("Not found");
        return;
      }
      if (reqUrl.searchParams.get("state") !== state) {
        res.writeHead(400).end("State mismatch");
        reject(new Error("OAuth state mismatch"));
        server.close();
        return;
      }
      const authCode = reqUrl.searchParams.get("code");
      if (!authCode) {
        res.writeHead(400).end("Missing authorization code");
        reject(new Error("No authorization code returned"));
        server.close();
        return;
      }
      res.writeHead(200, { "Content-Type": "text/html" }).end(
        "<html><body>Signed in. You can close this tab and return to the terminal.</body></html>",
      );
      resolve(authCode);
      server.close();
    });
    server.listen(REDIRECT_PORT, "127.0.0.1", () => {
      console.log(`Open this URL to sign in with ChatGPT:\n\n${url.toString()}\n`);
      openBrowser(url.toString());
    });
    server.on("error", reject);
  });

  const tokens = await exchangeCode(code, verifier);
  const auth: StoredAuth = {
    access_token: tokens.access_token,
    refresh_token: tokens.refresh_token,
    id_token: tokens.id_token,
    account_id: extractAccountId(tokens.id_token),
    expires_at: Date.now() + tokens.expires_in * 1000,
  };
  saveAuth(auth);
  return auth;
}

/** Returns a live access token, refreshing on disk if it's expired. */
export async function getValidAuth(): Promise<StoredAuth> {
  const auth = loadAuth();
  if (!auth) throw new Error("Not signed in — call login() first.");

  if (Date.now() < auth.expires_at - 30_000) return auth;

  const tokens = await refreshTokens(auth.refresh_token);
  const refreshed: StoredAuth = {
    access_token: tokens.access_token,
    refresh_token: tokens.refresh_token,
    id_token: tokens.id_token,
    account_id: extractAccountId(tokens.id_token),
    expires_at: Date.now() + tokens.expires_in * 1000,
  };
  saveAuth(refreshed);
  return refreshed;
}

// ============================================================================
// Chat
// ============================================================================

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
      "chatgpt-account-id": auth.account_id,
      "OpenAI-Beta": "responses=experimental",
      originator: "codex_cli_rs",
      session_id: sessionId,
    },
    body: JSON.stringify({
      model: opts.model ?? DEFAULT_MODEL,
      instructions: opts.instructions ?? "You are a helpful assistant.",
      input: toResponsesInput(messages),
      stream: true,
      store: false, // Codex backend rejects `store: true` — must be explicit
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
