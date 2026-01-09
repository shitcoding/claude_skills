import { createServer } from "http";
import { homedir } from "os";
import { join } from "path";
import { chmod, mkdir, readFile, writeFile } from "fs/promises";
import { randomBytes } from "crypto";
import { execSync } from "child_process";
import { existsSync } from "fs";
import open from "open";

const CONFIG_DIR = join(homedir(), ".clawdbot", "credentials", "ticktick-cli");
const CONFIG_FILE = join(CONFIG_DIR, "config.json");
const PASS_PREFIX = "ticktick-cli";

const OAUTH_BASE = "https://ticktick.com/oauth";
const API_BASE = "https://api.ticktick.com/open/v1";
const DEFAULT_REDIRECT_PORT = 8080;
const DEFAULT_REDIRECT_URI = `http://localhost:${DEFAULT_REDIRECT_PORT}`;

function generateState(): string {
  return `ticktick-cli-${randomBytes(16).toString("hex")}`;
}

// === Pass integration ===

function passGet(key: string): string | null {
  try {
    return execSync(`pass show ${PASS_PREFIX}/${key}`, {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return null;
  }
}

function passSet(key: string, value: string): void {
  execSync(`pass insert -f -m ${PASS_PREFIX}/${key}`, {
    input: value,
    encoding: "utf-8",
    stdio: ["pipe", "pipe", "pipe"],
  });
}

function passDelete(key: string): void {
  try {
    execSync(`pass rm -f ${PASS_PREFIX}/${key}`, {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch {
    // Ignore if key doesn't exist
  }
}

// === Config types ===

// JSON config (non-sensitive metadata only)
interface JsonConfig {
  tokenExpiry?: number;
  redirectUri?: string;
}

// Full config (includes secrets from pass)
export interface TickTickConfig {
  clientId: string;
  clientSecret: string;
  accessToken?: string;
  refreshToken?: string;
  tokenExpiry?: number;
  redirectUri?: string;
}

export async function ensureConfigDir(): Promise<void> {
  if (!existsSync(CONFIG_DIR)) {
    await mkdir(CONFIG_DIR, { recursive: true, mode: 0o700 });
  }
}

export async function loadConfig(): Promise<TickTickConfig | null> {
  try {
    // Load credentials from pass
    const clientId = passGet("client-id");
    const clientSecret = passGet("client-secret");
    if (!clientId || !clientSecret) {
      return null;
    }

    // Load metadata from JSON (optional)
    let jsonConfig: JsonConfig = {};
    try {
      const data = await readFile(CONFIG_FILE, "utf-8");
      jsonConfig = JSON.parse(data);
    } catch {
      // JSON config is optional
    }

    const config: TickTickConfig = {
      clientId,
      clientSecret,
      tokenExpiry: jsonConfig.tokenExpiry,
      redirectUri: jsonConfig.redirectUri || DEFAULT_REDIRECT_URI,
    };

    // Load optional tokens from pass
    const accessToken = passGet("access-token");
    if (accessToken) {
      config.accessToken = accessToken;
    }

    const refreshToken = passGet("refresh-token");
    if (refreshToken) {
      config.refreshToken = refreshToken;
    }

    return config;
  } catch {
    return null;
  }
}

export async function saveConfig(config: TickTickConfig): Promise<void> {
  await ensureConfigDir();

  // Save metadata to JSON (non-sensitive only)
  const jsonConfig: JsonConfig = {
    tokenExpiry: config.tokenExpiry,
    redirectUri: config.redirectUri,
  };
  await writeFile(CONFIG_FILE, JSON.stringify(jsonConfig, null, 2), { mode: 0o600 });
  await chmod(CONFIG_DIR, 0o700).catch(() => {});
  await chmod(CONFIG_FILE, 0o600).catch(() => {});

  // Save all credentials to pass
  if (config.clientId) {
    passSet("client-id", config.clientId);
  }
  if (config.clientSecret) {
    passSet("client-secret", config.clientSecret);
  }
  if (config.accessToken) {
    passSet("access-token", config.accessToken);
  }
  if (config.refreshToken) {
    passSet("refresh-token", config.refreshToken);
  }
}

export async function getValidToken(): Promise<string> {
  const config = await loadConfig();
  if (!config) {
    throw new Error(
      "Not authenticated. Run 'ticktick auth' to set up credentials."
    );
  }

  if (!config.accessToken) {
    throw new Error(
      "No access token found. Run 'ticktick auth' to authenticate."
    );
  }

  // Check if token is expired (with 5 min buffer)
  if (config.tokenExpiry && Date.now() > config.tokenExpiry - 300000) {
    if (config.refreshToken) {
      return await refreshAccessToken(config);
    }
    throw new Error("Token expired. Run 'ticktick auth' to re-authenticate.");
  }

  return config.accessToken;
}

async function refreshAccessToken(config: TickTickConfig): Promise<string> {
  const credentials = Buffer.from(
    `${config.clientId}:${config.clientSecret}`
  ).toString("base64");

  const response = await fetch(`${OAUTH_BASE}/token`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${credentials}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: config.refreshToken!,
    }),
  });

  if (!response.ok) {
    throw new Error(
      `Failed to refresh token: ${response.status} ${response.statusText}`
    );
  }

  const data = await response.json();

  config.accessToken = data.access_token;
  if (data.refresh_token) {
    config.refreshToken = data.refresh_token;
  }
  config.tokenExpiry = Date.now() + data.expires_in * 1000;

  await saveConfig(config);
  return config.accessToken;
}

export async function setupCredentials(
  clientId: string,
  clientSecret: string
): Promise<void> {
  const config = (await loadConfig()) || ({} as TickTickConfig);
  config.clientId = clientId;
  config.clientSecret = clientSecret;
  config.redirectUri = DEFAULT_REDIRECT_URI;
  await saveConfig(config);
  console.log("Credentials saved successfully.");
}

export async function authenticate(): Promise<void> {
  const config = await loadConfig();
  if (!config || !config.clientId || !config.clientSecret) {
    throw new Error(
      "No credentials found. Run 'ticktick auth --client-id <id> --client-secret <secret>' first."
    );
  }

  const redirectUri = config.redirectUri || DEFAULT_REDIRECT_URI;
  const port = new URL(redirectUri).port || DEFAULT_REDIRECT_PORT;
  const state = generateState();

  // Create a one-time local server to handle the OAuth callback
  const authCode = await new Promise<string>((resolve, reject) => {
    const server = createServer((req, res) => {
      const url = new URL(req.url!, `http://localhost:${port}`);

      if (url.pathname === "/") {
        const code = url.searchParams.get("code");
        const error = url.searchParams.get("error");
        const returnedState = url.searchParams.get("state");

        if (!returnedState || returnedState !== state) {
          res.writeHead(400, { "Content-Type": "text/html" });
          res.end(
            "<html><body><h1>Authentication Failed</h1><p>Invalid OAuth state.</p><p>You can close this window.</p></body></html>"
          );
          server.close();
          reject(new Error("Invalid OAuth state."));
          return;
        }

        if (error) {
          res.writeHead(400, { "Content-Type": "text/html" });
          res.end(
            `<html><body><h1>Authentication Failed</h1><p>Error: ${error}</p><p>You can close this window.</p></body></html>`
          );
          server.close();
          reject(new Error(`OAuth error: ${error}`));
          return;
        }

        if (code) {
          res.writeHead(200, { "Content-Type": "text/html" });
          res.end(
            "<html><body><h1>Authentication Successful!</h1><p>You can close this window and return to the terminal.</p></body></html>"
          );
          server.close();
          resolve(code);
          return;
        }
      }

      res.writeHead(404);
      res.end("Not found");
    });

    server.listen(port, "127.0.0.1", () => {
      const authUrl = `${OAUTH_BASE}/authorize?scope=tasks:read%20tasks:write&client_id=${encodeURIComponent(config.clientId)}&state=${encodeURIComponent(state)}&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code`;

      console.log("\nOpening browser for authentication...");
      console.log(`If browser doesn't open, visit:\n${authUrl}\n`);

      open(authUrl).catch(() => {
        console.log(
          "Could not open browser automatically. Please open the URL above manually."
        );
      });
    });

    // Timeout after 5 minutes
    setTimeout(() => {
      server.close();
      reject(new Error("Authentication timed out. Please try again."));
    }, 300000);
  });

  // Exchange the code for tokens
  const credentials = Buffer.from(
    `${config.clientId}:${config.clientSecret}`
  ).toString("base64");

  const tokenResponse = await fetch(`${OAUTH_BASE}/token`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${credentials}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: authCode,
      redirect_uri: redirectUri,
    }),
  });

  if (!tokenResponse.ok) {
    const errorText = await tokenResponse.text();
    throw new Error(
      `Failed to exchange code for token: ${tokenResponse.status} - ${errorText}`
    );
  }

  const tokenData = await tokenResponse.json();

  config.accessToken = tokenData.access_token;
  config.refreshToken = tokenData.refresh_token;
  config.tokenExpiry = Date.now() + tokenData.expires_in * 1000;

  await saveConfig(config);
  console.log("Authentication successful! Tokens saved.");
}

export async function checkAuth(): Promise<boolean> {
  try {
    await getValidToken();
    return true;
  } catch {
    return false;
  }
}

export async function logout(): Promise<void> {
  const config = await loadConfig();
  if (config) {
    // Remove tokens from pass (keep client-id and client-secret)
    passDelete("access-token");
    passDelete("refresh-token");

    // Update JSON config to remove tokenExpiry
    const jsonConfig: JsonConfig = {
      redirectUri: config.redirectUri,
    };
    await ensureConfigDir();
    await writeFile(CONFIG_FILE, JSON.stringify(jsonConfig, null, 2), { mode: 0o600 });

    console.log("Logged out successfully. Credentials preserved.");
  } else {
    console.log("No configuration found.");
  }
}

export async function authenticateManual(): Promise<void> {
  const config = await loadConfig();
  if (!config || !config.clientId || !config.clientSecret) {
    throw new Error(
      "No credentials found. Run 'ticktick auth --client-id <id> --client-secret <secret> --manual' first."
    );
  }

  const redirectUri = config.redirectUri || DEFAULT_REDIRECT_URI;
  const state = generateState();

  const authUrl = `${OAUTH_BASE}/authorize?scope=tasks:read%20tasks:write&client_id=${encodeURIComponent(config.clientId)}&state=${encodeURIComponent(state)}&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code`;

  console.log("\n=== Manual Authentication ===\n");
  console.log("1. Open this URL in your browser:\n");
  console.log(authUrl);
  console.log("\n2. Authorize the app");
  console.log("3. You'll be redirected to a URL like: http://localhost:8080/?code=XXXXX&state=STATE");
  console.log("4. Copy that ENTIRE redirect URL and paste it below:\n");

  // Read from stdin
  const reader = Bun.stdin.stream().getReader();
  const decoder = new TextDecoder();
  
  process.stdout.write("Paste redirect URL: ");
  
  let input = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    input += decoder.decode(value);
    if (input.includes("\n")) break;
  }
  reader.releaseLock();

  const redirectUrl = input.trim();
  
  if (!redirectUrl) {
    throw new Error("No URL provided.");
  }

  // Extract the code from the URL
  let authCode: string;
  try {
    const url = new URL(redirectUrl);
    const returnedState = url.searchParams.get("state");
    if (!returnedState) {
      throw new Error("Missing state in redirect URL. Paste the full redirect URL.");
    }
    if (returnedState !== state) {
      throw new Error("State mismatch. Please restart auth.");
    }
    authCode = url.searchParams.get("code") || "";
    if (!authCode) {
      throw new Error("No code found in URL");
    }
  } catch (e) {
    throw new Error(`Invalid redirect URL: ${redirectUrl}`);
  }

  console.log("\nExchanging code for tokens...");

  // Exchange the code for tokens
  const credentials = Buffer.from(
    `${config.clientId}:${config.clientSecret}`
  ).toString("base64");

  const tokenResponse = await fetch(`${OAUTH_BASE}/token`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${credentials}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: authCode,
      redirect_uri: redirectUri,
    }),
  });

  if (!tokenResponse.ok) {
    const errorText = await tokenResponse.text();
    throw new Error(
      `Failed to exchange code for token: ${tokenResponse.status} - ${errorText}`
    );
  }

  const tokenData = await tokenResponse.json();

  config.accessToken = tokenData.access_token;
  config.refreshToken = tokenData.refresh_token;
  config.tokenExpiry = Date.now() + tokenData.expires_in * 1000;

  await saveConfig(config);
  console.log("\n✓ Authentication successful! Tokens saved.");
}
