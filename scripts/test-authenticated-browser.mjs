import { randomBytes, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { cp, mkdtemp, readFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createClient } from "@supabase/supabase-js";
import { fileURLToPath } from "node:url";

const LOOPBACK_HOSTNAMES = new Set(["127.0.0.1", "localhost", "[::1]"]);
const LOCAL_PROJECT_ID = "voya-os-auth-e2e";
const PINNED_SUPABASE_CLI = "supabase@2.109.1";
const LOCAL_APPLICATION_ORIGIN = "http://127.0.0.1:3102";
const LOCAL_SUPABASE_API_ORIGIN = "http://127.0.0.1:55321";
const LOCAL_DATABASE_HOST = "127.0.0.1";
const LOCAL_DATABASE_PORT = "55322";
const LOCAL_DATABASE_NAME = "postgres";
const LOCAL_DATABASE_USER = "postgres";
const SAFE_CHILD_ENVIRONMENT_KEYS = [
  "CI",
  "COMSPEC",
  "HOME",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "PATH",
  "PATHEXT",
  "PLAYWRIGHT_BROWSERS_PATH",
  "SYSTEMROOT",
  "SystemRoot",
  "TEMP",
  "TMP",
  "TMPDIR",
  "TZ",
  "USERPROFILE",
  "WINDIR",
  "XDG_CACHE_HOME",
];
const ISOLATED_NEXT_PROJECT_ENTRIES = [
  "next.config.ts",
  "next-env.d.ts",
  "node_modules",
  "package-lock.json",
  "package.json",
  "postcss.config.mjs",
  "public",
  "src",
  "tsconfig.json",
];

function requiredString(value, label) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${label} is required.`);
  }
  return value.trim();
}

export function assertLocalSupabaseUrl(
  value,
  { label = "Supabase URL", protocols = ["http:", "https:"] } = {},
) {
  const parsed = new URL(requiredString(value, label));
  if (!protocols.includes(parsed.protocol)) {
    throw new Error(`${label} uses an unsupported protocol.`);
  }
  if (!LOOPBACK_HOSTNAMES.has(parsed.hostname)) {
    throw new Error(`${label} must use a loopback host.`);
  }
  return parsed;
}

function assertDedicatedLocalSupabaseApiUrl(value) {
  const parsed = assertLocalSupabaseUrl(value, {
    label: "Local Supabase API URL",
    protocols: ["http:", "https:"],
  });
  if (
    parsed.protocol !== "http:"
    || parsed.origin !== LOCAL_SUPABASE_API_ORIGIN
    || parsed.username
    || parsed.password
    || parsed.pathname !== "/"
    || parsed.search
    || parsed.hash
  ) {
    throw new Error("Local Supabase API URL must identify the dedicated local API.");
  }
  return parsed;
}

function assertDedicatedLocalDatabaseUrl(value) {
  const parsed = assertLocalSupabaseUrl(value, {
    label: "Local Supabase database URL",
    protocols: ["postgres:", "postgresql:"],
  });
  const database = decodeURIComponent(parsed.pathname.replace(/^\/+/, ""));
  if (
    parsed.hostname !== LOCAL_DATABASE_HOST
    || parsed.port !== LOCAL_DATABASE_PORT
    || decodeURIComponent(parsed.username) !== LOCAL_DATABASE_USER
    || database !== LOCAL_DATABASE_NAME
    || !parsed.password
    || parsed.search
    || parsed.hash
  ) {
    throw new Error("Local Supabase database URL must identify the dedicated local database.");
  }
  return parsed;
}

function selectSafeChildEnvironment(environment) {
  const safeEnvironment = {};
  for (const key of SAFE_CHILD_ENVIRONMENT_KEYS) {
    if (typeof environment[key] === "string" && environment[key] !== "") {
      safeEnvironment[key] = environment[key];
    }
  }
  safeEnvironment.PATH = requiredString(environment.PATH, "Child process PATH");
  return safeEnvironment;
}

export function assertDisposableLocalProject({
  projectId,
  disposableAcknowledgement,
}) {
  if (projectId !== LOCAL_PROJECT_ID) {
    throw new Error(`Authenticated browser tests require the dedicated local project ${LOCAL_PROJECT_ID}.`);
  }
  if (disposableAcknowledgement !== "1") {
    throw new Error("Set VOYA_AUTH_E2E_DISPOSABLE=1 to acknowledge destructive local fixture setup.");
  }
  return projectId;
}

export function assertLocalSupabaseStatus(status) {
  const apiUrl = requiredString(status?.API_URL, "Local Supabase API URL");
  const databaseUrl = requiredString(status?.DB_URL, "Local Supabase database URL");
  const publishableKey = requiredString(
    status?.ANON_KEY ?? status?.PUBLISHABLE_KEY,
    "Local Supabase publishable key",
  );
  const serviceRoleKey = requiredString(
    status?.SERVICE_ROLE_KEY ?? status?.SECRET_KEY,
    "Local Supabase service role key",
  );

  assertDedicatedLocalSupabaseApiUrl(apiUrl);
  assertDedicatedLocalDatabaseUrl(databaseUrl);

  return { apiUrl, databaseUrl, publishableKey, serviceRoleKey };
}

export function assertSafeLocalSupabaseCommand(args) {
  const command = [...args];
  const signature = command.join(" ");
  const isStart = signature === "start";
  const isStop = signature === "stop";
  const isStatus = signature === "status -o json";
  const isLocalReset = signature === "db reset --local --no-seed";

  if (!isStart && !isStop && !isStatus && !isLocalReset) {
    throw new Error(`Supabase command is not permitted by the local test harness.`);
  }
  return command;
}

export function buildLocalSupabaseInvocation(args) {
  return {
    command: "npx",
    args: ["--yes", PINNED_SUPABASE_CLI, ...assertSafeLocalSupabaseCommand(args)],
  };
}

export function buildLocalPsqlInvocation(databaseUrl) {
  const parsed = assertDedicatedLocalDatabaseUrl(databaseUrl);
  const username = decodeURIComponent(parsed.username);
  const password = decodeURIComponent(parsed.password);
  const database = decodeURIComponent(parsed.pathname.replace(/^\/+/, ""));
  return {
    command: "psql",
    args: [
      "--host", parsed.hostname.replace(/^\[|\]$/g, ""),
      "--port", requiredString(parsed.port, "Local Supabase database port"),
      "--username", username,
      "--dbname", database,
      "--no-password",
      "--no-psqlrc",
      "--set", "ON_ERROR_STOP=1",
    ],
    environment: { PGPASSWORD: password },
  };
}

export function buildDisposablePublicCleanupSql() {
  return `
DO $$
DECLARE
  public_tables text;
BEGIN
  SELECT string_agg(format('%I.%I', schemaname, tablename), ', ' ORDER BY tablename)
    INTO public_tables
  FROM pg_tables
  WHERE schemaname = 'public';

  IF public_tables IS NOT NULL THEN
    EXECUTE 'TRUNCATE TABLE ' || public_tables || ' CASCADE';
  END IF;
END;
$$;
`;
}

export async function orchestrateAuthenticatedBrowser({
  environment,
  readProjectId,
  runSupabase,
  createFixtures,
  runPlaywright,
}) {
  const projectId = await readProjectId();
  assertDisposableLocalProject({
    projectId,
    disposableAcknowledgement: environment.VOYA_AUTH_E2E_DISPOSABLE,
  });

  const statusCommand = assertSafeLocalSupabaseCommand(["status", "-o", "json"]);
  let startedStack = false;
  let cleanupFixtures;
  try {
    let statusResult;
    try {
      statusResult = await runSupabase(statusCommand);
    } catch {
      startedStack = true;
      await runSupabase(assertSafeLocalSupabaseCommand(["start"]));
      statusResult = await runSupabase(statusCommand);
    }

    const status = assertLocalSupabaseStatus(JSON.parse(statusResult.stdout));
    await runSupabase(
      assertSafeLocalSupabaseCommand(["db", "reset", "--local", "--no-seed"]),
    );
    const fixtureSet = await createFixtures(status);
    cleanupFixtures = fixtureSet.cleanup;
    return await runPlaywright(status, fixtureSet.fixtures);
  } finally {
    try {
      if (cleanupFixtures) await cleanupFixtures();
    } finally {
      if (startedStack) {
        await runSupabase(assertSafeLocalSupabaseCommand(["stop"]));
      }
    }
  }
}

async function runProcess(
  command,
  args,
  {
    cwd = process.cwd(),
    environment = process.env,
    inherit = false,
    input,
  } = {},
) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: environment,
      stdio: inherit ? "inherit" : [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk) => { stdout += chunk; });
    child.stderr?.on("data", (chunk) => { stderr += chunk; });
    if (input !== undefined) child.stdin?.end(input);
    const timeout = setTimeout(() => child.kill("SIGTERM"), 180_000);
    child.once("error", reject);
    child.once("exit", (code) => {
      clearTimeout(timeout);
      if (code === 0) resolve({ stdout });
      else reject(new Error(`${command} ${args.join(" ")} failed with exit code ${code ?? "unknown"}.`, {
        cause: stderr ? new Error("Child process reported an error.") : undefined,
      }));
    });
  });
}

async function runLocalDatabase(databaseUrl, sql) {
  const invocation = buildLocalPsqlInvocation(databaseUrl);
  return runProcess(invocation.command, invocation.args, {
    environment: { ...process.env, ...invocation.environment },
    input: sql,
  });
}

async function readLocalProjectId() {
  const config = await readFile("supabase/config.toml", "utf8");
  const match = config.match(/^\s*project_id\s*=\s*"([^"]+)"\s*$/m);
  if (!match) throw new Error("supabase/config.toml must declare project_id.");
  return match[1];
}

async function createSyntheticFixtures(status) {
  const admin = createClient(status.apiUrl, status.serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const runId = randomUUID();
  const password = `Voya-Local-${randomBytes(24).toString("base64url")}`;
  const credentials = {
    "single-membership": { email: `auth-e2e-${runId}-single@voya.invalid`, password },
    "multi-membership": { email: `auth-e2e-${runId}-multi@voya.invalid`, password },
    suspended: { email: `auth-e2e-${runId}-suspended@voya.invalid`, password },
  };
  const userIds = [];
  const organizationIds = [randomUUID(), randomUUID()];
  const bookingPropertyId = randomUUID();
  const bookingClientId = randomUUID();

  function uuidLiteral(value, label) {
    const normalized = requiredString(value, label);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(normalized)) {
      throw new Error(`${label} must be a UUID.`);
    }
    return `'${normalized}'::uuid`;
  }

  async function cleanup() {
    try {
      await runLocalDatabase(status.databaseUrl, buildDisposablePublicCleanupSql());
    } finally {
      await Promise.all(userIds.map((id) => admin.auth.admin.deleteUser(id)));
    }
  }

  try {
    for (const credential of Object.values(credentials)) {
      const { data, error } = await admin.auth.admin.createUser({
        ...credential,
        email_confirm: true,
      });
      if (error || !data.user) throw new Error("Synthetic local Auth user creation failed.");
      userIds.push(data.user.id);
    }
    const organizationOneId = uuidLiteral(organizationIds[0], "Synthetic organization ID");
    const organizationTwoId = uuidLiteral(organizationIds[1], "Synthetic organization ID");
    const singleUserId = uuidLiteral(userIds[0], "Synthetic user ID");
    const multiUserId = uuidLiteral(userIds[1], "Synthetic user ID");
    const suspendedUserId = uuidLiteral(userIds[2], "Synthetic user ID");
    await runLocalDatabase(status.databaseUrl, `
BEGIN;
INSERT INTO public.organizations (id, name, slug) VALUES
  (${organizationOneId}, 'Voya Local Alpha', 'auth-e2e-${runId}-alpha'),
  (${organizationTwoId}, 'Voya Local Beta', 'auth-e2e-${runId}-beta');
INSERT INTO public.profiles (id, display_name) VALUES
  (${singleUserId}, 'Local Auth Fixture 1'),
  (${multiUserId}, 'Local Auth Fixture 2'),
  (${suspendedUserId}, 'Local Auth Fixture 3');
INSERT INTO public.organization_memberships (organization_id, user_id, role, status) VALUES
  (${organizationOneId}, ${singleUserId}, 'owner', 'active'),
  (${organizationOneId}, ${multiUserId}, 'manager', 'active'),
  (${organizationTwoId}, ${multiUserId}, 'operations', 'active'),
  (${organizationTwoId}, ${suspendedUserId}, 'viewer', 'suspended');
INSERT INTO public.properties (id, organization_id, code, name, timezone, status, idempotency_key)
VALUES (${uuidLiteral(bookingPropertyId, "Synthetic booking property ID")}, ${organizationOneId}, 'E2E-BOOKING', 'إقامة E2E', 'Africa/Cairo', 'active', 'auth-e2e-${runId}-property');
INSERT INTO public.clients (id, organization_id, display_name, idempotency_key)
VALUES (${uuidLiteral(bookingClientId, "Synthetic booking client ID")}, ${organizationOneId}, 'عميل حجز E2E', 'auth-e2e-${runId}-client');
COMMIT;
`);
    return { fixtures: credentials, cleanup };
  } catch (error) {
    await cleanup();
    throw error;
  }
}

export function buildPlaywrightEnvironment(environment, status, fixtures) {
  assertDedicatedLocalSupabaseApiUrl(status.apiUrl);
  return {
    ...selectSafeChildEnvironment(environment),
    VOYA_AUTH_E2E_LOCAL: "1",
    VOYA_AUTH_E2E_APP_ORIGIN: LOCAL_APPLICATION_ORIGIN,
    VOYA_AUTH_E2E_FIXTURES: JSON.stringify(fixtures),
    NEXT_PUBLIC_SUPABASE_URL: status.apiUrl,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: requiredString(
      status.publishableKey,
      "Local Supabase publishable key",
    ),
  };
}

export function buildNextEnvironment(environment) {
  if (
    environment.VOYA_AUTH_E2E_LOCAL !== "1"
    || environment.VOYA_AUTH_E2E_APP_ORIGIN !== LOCAL_APPLICATION_ORIGIN
  ) {
    throw new Error("Isolated Next.js requires the dedicated local authenticated test origin.");
  }
  const apiUrl = requiredString(
    environment.NEXT_PUBLIC_SUPABASE_URL,
    "Local Supabase API URL",
  );
  assertDedicatedLocalSupabaseApiUrl(apiUrl);
  return {
    ...selectSafeChildEnvironment(environment),
    VOYA_AUTH_E2E_LOCAL: "1",
    VOYA_AUTH_E2E_APP_ORIGIN: LOCAL_APPLICATION_ORIGIN,
    VOYA_APP_URL: LOCAL_APPLICATION_ORIGIN,
    NEXT_PUBLIC_SUPABASE_URL: apiUrl,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: requiredString(
      environment.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
      "Local Supabase publishable key",
    ),
  };
}

export function buildIsolatedNextInvocations(repositoryRoot) {
  const nextCli = resolve(repositoryRoot, "node_modules/next/dist/bin/next");
  return {
    build: {
      command: process.execPath,
      args: [nextCli, "build", "--webpack"],
    },
    start: {
      command: process.execPath,
      args: [
        nextCli,
        "start",
        "--hostname",
        "127.0.0.1",
        "--port",
        "3102",
      ],
    },
  };
}

async function runLocalPlaywright(status, fixtures) {
  const environment = buildPlaywrightEnvironment(process.env, status, fixtures);
  await runProcess(
    process.execPath,
    [
      "node_modules/@playwright/test/cli.js",
      "test",
      "e2e/authenticated-workspace.spec.ts",
      "--workers=1",
    ],
    { environment, inherit: true },
  );
}

async function serveIsolatedNextApplication() {
  const repositoryRoot = process.cwd();
  const isolatedRoot = await mkdtemp(join(tmpdir(), "voya-os-auth-e2e-next-"));
  try {
    await Promise.all(ISOLATED_NEXT_PROJECT_ENTRIES.map((entry) => (
      entry === "node_modules"
        ? symlink(resolve(repositoryRoot, entry), join(isolatedRoot, entry))
        : cp(resolve(repositoryRoot, entry), join(isolatedRoot, entry), { recursive: true })
    )));
    const environment = buildNextEnvironment(process.env);
    const invocations = buildIsolatedNextInvocations(repositoryRoot);
    await runProcess(invocations.build.command, invocations.build.args, {
      cwd: isolatedRoot,
      environment,
      inherit: true,
    });
    const nextProcess = spawn(
      invocations.start.command,
      invocations.start.args,
      {
        cwd: isolatedRoot,
        env: environment,
        stdio: "inherit",
      },
    );
    await new Promise((resolveExit, rejectExit) => {
      let stopping = false;
      const stop = (signal) => {
        stopping = true;
        nextProcess.kill(signal);
      };
      const stopTerm = () => stop("SIGTERM");
      const stopInterrupt = () => stop("SIGINT");
      process.once("SIGTERM", stopTerm);
      process.once("SIGINT", stopInterrupt);
      nextProcess.once("error", rejectExit);
      nextProcess.once("exit", (code) => {
        process.removeListener("SIGTERM", stopTerm);
        process.removeListener("SIGINT", stopInterrupt);
        if (code === 0 || stopping) resolveExit();
        else rejectExit(new Error(`Isolated Next.js server exited with code ${code ?? "unknown"}.`));
      });
    });
  } finally {
    await rm(isolatedRoot, { recursive: true, force: true });
  }
}

async function main() {
  await orchestrateAuthenticatedBrowser({
    environment: process.env,
    readProjectId: readLocalProjectId,
    runSupabase: (args) => {
      const invocation = buildLocalSupabaseInvocation(args);
      return runProcess(invocation.command, invocation.args);
    },
    createFixtures: createSyntheticFixtures,
    runPlaywright: runLocalPlaywright,
  });
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  const operation = process.argv[2] === "--serve-next"
    ? serveIsolatedNextApplication()
    : main();
  operation.catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "Authenticated browser harness failed."}\n`);
    process.exitCode = 1;
  });
}
