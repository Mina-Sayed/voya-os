import { spawn } from "node:child_process";
import { lstat, mkdtemp, readFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SAFE_CHILD_ENVIRONMENT_KEYS = [
  "CI",
  "COMSPEC",
  "HOME",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "PATH",
  "PATHEXT",
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
const PRODUCTION_SMOKE_SUPABASE_URL = "https://build-check.supabase.co";
const PRODUCTION_SMOKE_SUPABASE_KEY = "build-check-key";
const PRODUCTION_SMOKE_APP_URL = "https://app.build-check.example";
const PROTECTED_ROUTES = [
  "/workspace",
  "/workspace/activity",
  "/workspace/approvals",
  "/workspace/availability",
  "/workspace/bookings",
  "/workspace/tasks",
  "/workspace/transport",
  "/workspace/clients",
  "/workspace/leads",
  "/workspace/notifications",
  "/workspace/properties",
  "/workspace/property-owners",
];
const NONCE_REQUIRED_PUBLIC_ROUTES = ["/", "/sign-in"];
const REQUIRED_RUNTIME_ARTIFACTS = [".next", "package.json", "node_modules"];

async function pathExists(path) {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

export async function createProductionRuntimeRoot({ sourceRoot = process.cwd() } = {}) {
  const resolvedSourceRoot = resolve(sourceRoot);
  const runtimeRoot = await mkdtemp(join(tmpdir(), "voya-production-auth-runtime-"));
  let cleanedUp = false;
  const cleanup = async () => {
    if (cleanedUp) return;
    cleanedUp = true;
    await rm(runtimeRoot, { force: true, maxRetries: 3, recursive: true });
  };

  try {
    const artifacts = [...REQUIRED_RUNTIME_ARTIFACTS];
    if (await pathExists(join(resolvedSourceRoot, "public"))) artifacts.push("public");

    for (const artifact of artifacts) {
      const sourcePath = join(resolvedSourceRoot, artifact);
      if (!await pathExists(sourcePath)) {
        throw new Error(`Required production artifact is missing: ${artifact}`);
      }
      const sourceStats = await lstat(sourcePath);
      await symlink(sourcePath, join(runtimeRoot, artifact), sourceStats.isDirectory() ? "dir" : "file");
    }

    return { cleanup, root: runtimeRoot };
  } catch (error) {
    await cleanup();
    throw error;
  }
}

export function assertLoopbackOrigin(value) {
  let origin;
  try {
    origin = new URL(value);
  } catch {
    throw new Error("Production test origin must be a root loopback HTTP origin.");
  }

  if (
    origin.protocol !== "http:"
    || origin.hostname !== "127.0.0.1"
    || origin.username
    || origin.password
    || origin.pathname !== "/"
    || origin.search
    || origin.hash
    || origin.href !== `${origin.origin}/`
  ) {
    throw new Error("Production test origin must be a root loopback HTTP origin.");
  }
  return origin;
}

function createLoopbackOrigin(port) {
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("Production test port must be a valid TCP port.");
  }
  return assertLoopbackOrigin(`http://127.0.0.1:${port}`);
}

export function buildProductionChildEnvironment(environment) {
  const childEnvironment = {};
  for (const key of SAFE_CHILD_ENVIRONMENT_KEYS) {
    if (typeof environment[key] === "string" && environment[key] !== "") {
      childEnvironment[key] = environment[key];
    }
  }
  if (!childEnvironment.PATH) {
    throw new Error("Child process PATH is required.");
  }

  return {
    ...childEnvironment,
    NODE_ENV: "production",
    NEXT_PUBLIC_SUPABASE_URL: PRODUCTION_SMOKE_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: PRODUCTION_SMOKE_SUPABASE_KEY,
    VOYA_APP_URL: PRODUCTION_SMOKE_APP_URL,
  };
}

function waitForReady(server, timeoutMs = 15_000) {
  return new Promise((resolveReady, rejectReady) => {
    let output = "";
    const timeout = setTimeout(() => finish(new Error("Production server did not become ready.")), timeoutMs);
    const inspect = (chunk) => {
      output += chunk.toString();
      if (output.includes("Ready")) finish();
    };
    const onExit = (code) => finish(new Error(`Production server exited before readiness with code ${code ?? "unknown"}.`));
    const onError = () => finish(new Error("Production server could not be started."));
    const finish = (error) => {
      clearTimeout(timeout);
      server.stdout.off("data", inspect);
      server.stderr.off("data", inspect);
      server.off("exit", onExit);
      server.off("error", onError);
      if (error) rejectReady(error);
      else resolveReady();
    };

    server.stdout.on("data", inspect);
    server.stderr.on("data", inspect);
    server.once("exit", onExit);
    server.once("error", onError);
  });
}

function waitForExit(server, timeoutMs) {
  if (server.exitCode !== null || server.signalCode !== null) return Promise.resolve(true);
  return new Promise((resolveExit) => {
    const timeout = setTimeout(() => finish(false), timeoutMs);
    const onExit = () => finish(true);
    const finish = (exited) => {
      clearTimeout(timeout);
      server.off("exit", onExit);
      resolveExit(exited);
    };
    server.once("exit", onExit);
  });
}

async function stopServer(server) {
  if (server.exitCode !== null || server.signalCode !== null) return;

  const stoppedAfterTerm = waitForExit(server, 5_000);
  server.kill("SIGTERM");
  if (await stoppedAfterTerm) return;

  const stoppedAfterKill = waitForExit(server, 5_000);
  server.kill("SIGKILL");
  await stoppedAfterKill;
}

export function assertRequestTimeResponse(response, label) {
  const cacheControl = response.headers.get("cache-control") ?? "";
  if (response.headers.has("x-nextjs-prerender")) {
    throw new Error(`${label} was prerendered instead of evaluated per request.`);
  }
  if ((response.headers.get("x-nextjs-cache") ?? "").toUpperCase() === "HIT") {
    throw new Error(`${label} was served from the shared Next.js cache.`);
  }
  if (/s-maxage\s*=/i.test(cacheControl)) {
    throw new Error(`${label} permits shared-cache storage.`);
  }
}

export function assertProductionSecurityHeaders(response, label) {
  const contentSecurityPolicy = response.headers.get("content-security-policy") ?? "";
  if (!/script-src\s+'self'\s+'nonce-[^']+'\s+'strict-dynamic'/i.test(contentSecurityPolicy)) {
    throw new Error(`${label} is missing the production nonce-based CSP.`);
  }
  if (/unsafe-inline|unsafe-eval/i.test(contentSecurityPolicy)) {
    throw new Error(`${label} permits unsafe inline or eval script execution.`);
  }
  if (!/frame-ancestors\s+'none'/i.test(contentSecurityPolicy)) {
    throw new Error(`${label} is missing clickjacking protection.`);
  }
  for (const [header, expected] of [
    ["x-content-type-options", "nosniff"],
    ["x-frame-options", "DENY"],
    ["referrer-policy", "strict-origin-when-cross-origin"],
  ]) {
    if ((response.headers.get(header) ?? "").toLowerCase() !== expected.toLowerCase()) {
      throw new Error(`${label} is missing ${header}.`);
    }
  }
}

function assertUnauthenticatedRedirect(response, route, origin) {
  if (!response.redirected && ![301, 302, 303, 307, 308].includes(response.status)) {
    throw new Error(`Unauthenticated ${route} did not redirect to sign-in; received ${response.status}.`);
  }
  const location = response.headers.get("location");
  if (!location || new URL(location, origin).pathname !== "/sign-in") {
    throw new Error(`Unauthenticated ${route} did not redirect to /sign-in.`);
  }
}

export async function runProductionAuthRenderingSmoke({
  environment = process.env,
  port = 3200 + (process.pid % 500),
} = {}) {
  const origin = createLoopbackOrigin(port);
  const runtime = await createProductionRuntimeRoot();
  let server;

  try {
    server = spawn(
      process.execPath,
      ["node_modules/next/dist/bin/next", "start", "--hostname", "127.0.0.1", "--port", String(port)],
      {
        cwd: runtime.root,
        env: buildProductionChildEnvironment(environment),
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    const prerenderManifest = JSON.parse(await readFile(join(runtime.root, ".next/prerender-manifest.json"), "utf8"));
    const prerenderedProtectedRoute = PROTECTED_ROUTES.find((route) => prerenderManifest.routes[route]);
    if (prerenderedProtectedRoute) {
      throw new Error(`${prerenderedProtectedRoute} is present in the production prerender manifest.`);
    }
    const prerenderedNonceRoute = NONCE_REQUIRED_PUBLIC_ROUTES.find((route) => prerenderManifest.routes[route]);
    if (prerenderedNonceRoute) {
      throw new Error(`${prerenderedNonceRoute} is present in the production prerender manifest and cannot receive a request nonce.`);
    }
    await waitForReady(server);
    for (const route of NONCE_REQUIRED_PUBLIC_ROUTES) {
      const response = await fetch(new URL(route, origin), { redirect: "manual" });
      assertRequestTimeResponse(response, `public ${route} response`);
      assertProductionSecurityHeaders(response, `public ${route} response`);
      const body = await response.text();
      if (!/<script[^>]+nonce=['"][^'"]+['"]/i.test(body)) {
        throw new Error(`public ${route} response does not attach a nonce to framework scripts.`);
      }
    }
    const healthResponse = await fetch(new URL("/api/health", origin), { redirect: "manual" });
    assertRequestTimeResponse(healthResponse, "runtime health response");
    assertProductionSecurityHeaders(healthResponse, "runtime health response");
    if (healthResponse.status !== 200 || (await healthResponse.json()).status !== "ok") {
      throw new Error("runtime health endpoint did not report a healthy production configuration.");
    }
    for (const route of PROTECTED_ROUTES) {
      for (const [label, headers] of [
        ["unauthenticated", {}],
        ["cookie-bearing", { cookie: "sb-synthetic-auth-token=synthetic" }],
      ]) {
        const response = await fetch(new URL(route, origin), { headers, redirect: "manual" });
        assertRequestTimeResponse(response, `${label} ${route} response`);
        assertProductionSecurityHeaders(response, `${label} ${route} response`);
        if (label === "unauthenticated") assertUnauthenticatedRedirect(response, route, origin);
      }
    }
    process.stdout.write("Protected workspace responses are evaluated per request and are not shared-cacheable.\n");
  } finally {
    if (server) await stopServer(server);
    await runtime.cleanup();
  }
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : undefined;
if (invokedPath === fileURLToPath(import.meta.url)) {
  await runProductionAuthRenderingSmoke();
}
