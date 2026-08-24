import { execFileSync, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { resolve } from "node:path";

const LOCAL_SUPABASE_API_ORIGIN = "http://127.0.0.1:55321";
const LOCAL_APPLICATION_ORIGIN = "http://127.0.0.1:3102";
const LOCAL_SUPABASE_HEALTH_PATH = "/auth/v1/health";
const LOCAL_SUPABASE_READY_TIMEOUT_MS = 30_000;
const LOCAL_SUPABASE_READY_INTERVAL_MS = 250;

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

function runSupabaseCommand(args) {
  return execFileSync("supabase", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function commandStderr(error) {
  if (!error || typeof error !== "object" || !("stderr" in error)) return "";
  const stderr = error.stderr;
  return typeof stderr === "string" ? stderr : Buffer.isBuffer(stderr) ? stderr.toString("utf8") : "";
}

function runRequiredSupabaseCommand(run, args) {
  try {
    return run(args);
  } catch (error) {
    const stderr = commandStderr(error);
    if (args[0] === "migration" && /Remote migration versions not found in local migrations directory/u.test(stderr)) {
      throw new Error(
        "Local Supabase migration history is out of sync with this checkout. "
        + "Inspect `supabase migration list --local`; if the local data is disposable, run `supabase db reset --local --no-seed`, then retry.",
      );
    }
    throw new Error(`Local Supabase command failed: supabase ${args.join(" ")}.`);
  }
}

export function readLocalSupabaseStatus({ run = runSupabaseCommand } = {}) {
  const status = JSON.parse(run(["status", "-o", "json"]));
  const apiUrl = requiredString(statusValue(status, "API_URL"), "Local Supabase API URL");
  const publishableKey = requiredString(statusValue(status, "ANON_KEY", "PUBLISHABLE_KEY"), "Local Supabase publishable key");
  const serviceRoleKey = requiredString(statusValue(status, "SERVICE_ROLE_KEY", "SECRET_KEY"), "Local Supabase service-role key");
  if (apiUrl !== LOCAL_SUPABASE_API_ORIGIN) {
    throw new Error(`Local Supabase must run at ${LOCAL_SUPABASE_API_ORIGIN}.`);
  }
  return { apiUrl, publishableKey, serviceRoleKey };
}

const delay = (milliseconds) => new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));

export async function waitForLocalSupabase({
  apiUrl,
  fetchImpl = fetch,
  sleep = delay,
  now = () => Date.now(),
  timeoutMs = LOCAL_SUPABASE_READY_TIMEOUT_MS,
  intervalMs = LOCAL_SUPABASE_READY_INTERVAL_MS,
} = {}) {
  const healthUrl = `${apiUrl}${LOCAL_SUPABASE_HEALTH_PATH}`;
  const deadline = now() + timeoutMs;
  let lastStatus = null;

  while (now() < deadline) {
    try {
      const response = await fetchImpl(healthUrl, { cache: "no-store" });
      if (response.ok) return;
      lastStatus = response.status;
    } catch {
      // The local gateway can accept connections before Auth is ready.
    }
    const remaining = deadline - now();
    if (remaining <= 0) break;
    await sleep(Math.min(intervalMs, remaining));
  }

  const statusSuffix = lastStatus === null ? "" : ` (last HTTP status: ${lastStatus})`;
  throw new Error(`Local Supabase Auth did not become ready at ${healthUrl}${statusSuffix}.`);
}

export async function ensureLocalSupabaseReady({
  run = runSupabaseCommand,
  fetchImpl = fetch,
  sleep = delay,
  now = () => Date.now(),
  timeoutMs = LOCAL_SUPABASE_READY_TIMEOUT_MS,
  intervalMs = LOCAL_SUPABASE_READY_INTERVAL_MS,
} = {}) {
  runRequiredSupabaseCommand(run, ["start"]);
  runRequiredSupabaseCommand(run, ["migration", "up", "--local"]);
  const status = readLocalSupabaseStatus({
    run: (args) => runRequiredSupabaseCommand(run, args),
  });
  await waitForLocalSupabase({ apiUrl: status.apiUrl, fetchImpl, sleep, now, timeoutMs, intervalMs });
  return status;
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

export async function startLocalDevelopmentServer({ environment = process.env, spawnProcess = spawn } = {}) {
  const status = await ensureLocalSupabaseReady();
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
  startLocalDevelopmentServer().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "Local development server failed."}\n`);
    process.exitCode = 1;
  });
}
