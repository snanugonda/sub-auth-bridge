import http from "node:http";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  mkdirSync,
  readFileSync,
  writeFileSync,
  existsSync,
  renameSync,
  openSync,
  writeSync,
  closeSync,
  rmSync,
  statSync,
} from "node:fs";
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
  /**
   * Present when this credential was mirrored from an OpenClaw install
   * rather than obtained via our own login(). OpenAI rotates refresh
   * tokens (single-use) — refreshing an OpenClaw-sourced token ourselves
   * would silently invalidate OpenClaw's own copy. So a credential tagged
   * this way is never refreshed here; it's only ever re-synced (read-only)
   * from OpenClaw's own store. See scripts/import-openclaw-auth.sh.
   */
  source?: "openclaw";
}

const AUTH_DIR = join(homedir(), ".open-ai-sub-auth");
const AUTH_FILE = join(AUTH_DIR, "auth.json");
const LOCK_FILE = join(AUTH_DIR, "auth.lock");
const LOCK_STALE_MS = 15_000;
const LOCK_WAIT_TIMEOUT_MS = 5_000;
const LOCK_POLL_INTERVAL_MS = 150;

/** Reads `~/.open-ai-sub-auth/auth.json` as-is, no refresh, no network call. `null` if not signed in. */
export function loadAuth(): StoredAuth | null {
  if (!existsSync(AUTH_FILE)) return null;
  return JSON.parse(readFileSync(AUTH_FILE, "utf-8"));
}

// Write-to-temp-then-rename so concurrent readers never see a partial file:
// rename() is atomic on POSIX as long as source and destination share a
// filesystem, so every reader sees either the fully-old or fully-new file.
function saveAuth(auth: StoredAuth): void {
  mkdirSync(AUTH_DIR, { recursive: true });
  const tmp = join(AUTH_DIR, `auth.json.tmp-${process.pid}-${Date.now()}`);
  writeFileSync(tmp, JSON.stringify(auth, null, 2), { mode: 0o600 });
  renameSync(tmp, AUTH_FILE);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Exclusive-create lockfile: `wx` fails with EEXIST if another process
// already holds it. A stale lock (holder crashed mid-refresh) is reclaimed
// after LOCK_STALE_MS so a dead process can't wedge every consumer forever.
function tryAcquireLock(): boolean {
  try {
    const fd = openSync(LOCK_FILE, "wx");
    writeSync(fd, String(process.pid));
    closeSync(fd);
    return true;
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
    try {
      if (Date.now() - statSync(LOCK_FILE).mtimeMs > LOCK_STALE_MS) {
        rmSync(LOCK_FILE, { force: true });
        return tryAcquireLock();
      }
    } catch {
      // Lock vanished between the failed create and this check — retry once.
      return tryAcquireLock();
    }
    return false;
  }
}

function releaseLock(): void {
  try {
    rmSync(LOCK_FILE, { force: true });
  } catch {
    // Already gone — fine.
  }
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

// Guards the "check expiry -> refresh -> write" critical section so two
// processes sharing this machine's auth.json (e.g. the service and a CLI
// invocation) can't both refresh at once. OpenAI's refresh tokens are
// single-use/rotating, so a double-refresh would leave one caller holding
// an already-invalidated token. Losers of the lock poll for the winner's
// result instead of racing; they never attempt a second refresh call.
async function refreshWithLock(currentAuth: StoredAuth): Promise<StoredAuth> {
  const deadline = Date.now() + LOCK_WAIT_TIMEOUT_MS;
  while (true) {
    if (tryAcquireLock()) {
      try {
        // Someone else may have refreshed and written while we waited for the lock.
        const latest = loadAuth();
        if (latest && Date.now() < latest.expires_at - 30_000) return latest;

        const tokens = await refreshTokens(currentAuth.refresh_token);
        const refreshed: StoredAuth = {
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          id_token: tokens.id_token,
          account_id: extractAccountId(tokens.id_token),
          expires_at: Date.now() + tokens.expires_in * 1000,
        };
        saveAuth(refreshed);
        return refreshed;
      } finally {
        releaseLock();
      }
    }

    const latest = loadAuth();
    if (latest && Date.now() < latest.expires_at - 30_000) return latest;
    if (Date.now() > deadline) {
      throw new Error(
        "Timed out waiting for a concurrent token refresh (from another process using " +
          "this same auth.json) to finish. Try again.",
      );
    }
    await sleep(LOCK_POLL_INTERVAL_MS);
  }
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

  if (auth.source === "openclaw") {
    throw new Error(
      "OpenClaw-linked credential expired. This repo never refreshes an OpenClaw-sourced " +
        "token itself — doing so could invalidate OpenClaw's own session, since OpenAI's " +
        "refresh tokens are single-use. Run scripts/import-openclaw-auth.sh to pull " +
        "OpenClaw's current token, or run the login flow here for an independent session.",
    );
  }

  return refreshWithLock(auth);
}
