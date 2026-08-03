import http from "node:http";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import {
  AUTHORIZE_URL,
  TOKEN_URL,
  REDIRECT_URI,
  REDIRECT_PORT,
  SCOPE,
  CLIENT_ID,
  JWT_CLAIM_PATH,
} from "./constants.js";
import { generatePKCE, createState } from "./pkce.js";

export interface StoredAuth {
  access_token: string;
  refresh_token: string;
  id_token: string;
  account_id: string;
  expires_at: number; // epoch ms
}

const AUTH_DIR = join(homedir(), ".open-ai-sub-auth");
const AUTH_FILE = join(AUTH_DIR, "auth.json");

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
    // fall through — caller still prints the URL
  }
}

async function exchangeCode(code: string, verifier: string): Promise<{
  access_token: string;
  refresh_token: string;
  id_token: string;
  expires_in: number;
}> {
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
  if (!res.ok) {
    throw new Error(`token exchange failed: ${res.status} ${await res.text()}`);
  }
  return res.json();
}

async function refreshTokens(refreshToken: string): Promise<{
  access_token: string;
  refresh_token: string;
  id_token: string;
  expires_in: number;
}> {
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      client_id: CLIENT_ID,
      refresh_token: refreshToken,
    }),
  });
  if (!res.ok) {
    throw new Error(`token refresh failed: ${res.status} ${await res.text()}`);
  }
  return res.json();
}

/** Runs the full browser-based PKCE login flow and persists credentials. */
export async function login(): Promise<StoredAuth> {
  const { verifier, challenge } = generatePKCE();
  const state = createState();

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
  if (!auth) throw new Error("Not signed in — run the login flow first.");

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
