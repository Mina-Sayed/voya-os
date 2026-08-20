import { execFileSync, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { resolve } from "node:path";

const LOCAL_SUPABASE_API_ORIGIN = "http://127.0.0.1:55321";
const LOCAL_APPLICATION_ORIGIN = "http://127.0.0.1:3102";

function requiredString(value, label) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${label} is missing.`);
  }
  return value.trim();
}

function statusValue(status, ...keys) {
  for (const key of keys) {
    if (typeof status?.[key] === "string" && status[key].trim() !== "") return status[key].trim();
  }
  return null;
}

export function readLocalSupabaseStatus({ run = (args) => execFileSync("supabase", args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }) } = {}) {
  const status = JSON.parse(run(["status", "-o", "json"]));
  const apiUrl = requiredString(statusValue(status, "API_URL"), "Local Supabase API URL");
  const publishableKey = requiredString(statusValue(status, "ANON_KEY", "PUBLISHABLE_KEY"), "Local Supabase publishable key");
  const serviceRoleKey = requiredString(statusValue(status, "SERVICE_ROLE_KEY", "SECRET_KEY"), "Local Supabase service-role key");
  if (apiUrl !== LOCAL_SUPABASE_API_ORIGIN) {
    throw new Error(`Local Supabase must run at ${LOCAL_SUPABASE_API_ORIGIN}.`);
  }
  return { apiUrl, publishableKey, serviceRoleKey };
}

export function buildLocalDevelopmentEnvironment(environment, status) {
  const appUrl = environment.VOYA_APP_URL?.trim() || LOCAL_APPLICATION_ORIGIN;
  if (appUrl !== LOCAL_APPLICATION_ORIGIN) {
    throw new Error(`Local development must use ${LOCAL_APPLICATION_ORIGIN}.`);
  }
  return {
    PATH: environment.PATH,
    HOME: environment.HOME,
    LANG: environment.LANG,
    LC_ALL: environment.LC_ALL,
    TMPDIR: environment.TMPDIR,
    NODE_ENV: "development",
    VOYA_AUTH_E2E_LOCAL: "1",
    VOYA_APP_URL: appUrl,
    NEXT_PUBLIC_SUPABASE_URL: status.apiUrl,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: status.publishableKey,
    SUPABASE_SERVICE_ROLE_KEY: status.serviceRoleKey,
    AUTH_RATE_LIMIT_HMAC_SECRET: randomBytes(32).toString("hex"),
    OUTBOX_PAYLOAD_ENCRYPTION_KEY: randomBytes(32).toString("hex"),
  };
}

export function startLocalDevelopmentServer({ environment = process.env, spawnProcess = spawn } = {}) {
  const status = readLocalSupabaseStatus();
  const child = spawnProcess(
    process.execPath,
    [resolve(process.cwd(), "node_modules/next/dist/bin/next"), "dev", "--hostname", "127.0.0.1", "--port", "3102"],
    { env: buildLocalDevelopmentEnvironment(environment, status), stdio: "inherit" },
  );
  const forwardSignal = (signal) => child.kill(signal);
  process.once("SIGINT", () => forwardSignal("SIGINT"));
  process.once("SIGTERM", () => forwardSignal("SIGTERM"));
  child.once("exit", (code) => process.exit(code ?? 1));
  return child;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    startLocalDevelopmentServer();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : "Local development server failed."}\n`);
    process.exitCode = 1;
  }
}
