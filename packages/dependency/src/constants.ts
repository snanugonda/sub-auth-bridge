// OAuth + backend constants used by the official Codex CLI / OpenClaw for
// "Sign in with ChatGPT" (subscription auth, no per-token API billing).

export const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
export const AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
export const TOKEN_URL = "https://auth.openai.com/oauth/token";
export const REDIRECT_PORT = 1455;
export const REDIRECT_URI = `http://localhost:${REDIRECT_PORT}/auth/callback`;
export const SCOPE = "openid profile email offline_access";

export const CODEX_RESPONSES_URL = "https://chatgpt.com/backend-api/codex/responses";

export const OPENAI_HEADERS = {
  BETA: "OpenAI-Beta",
  ACCOUNT_ID: "chatgpt-account-id",
  ORIGINATOR: "originator",
} as const;

export const OPENAI_HEADER_VALUES = {
  BETA_RESPONSES: "responses=experimental",
  ORIGINATOR_CODEX: "codex_cli_rs",
} as const;

// JWT claim namespace OpenAI stuffs account info into.
export const JWT_CLAIM_PATH = "https://api.openai.com/auth";
