import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  access,
  mkdtemp,
  mkdir,
  readdir,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import * as productionRendering from "./test-production-auth-rendering.mjs";

const {
  assertLoopbackOrigin,
  assertProductionSecurityHeaders,
  assertRequestTimeResponse,
  buildProductionChildEnvironment,
  createProductionRuntimeRoot,
} = productionRendering;

function runNode(argumentsToPass, options) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(process.execPath, argumentsToPass, options);
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", rejectRun);
    child.once("exit", (code) => resolveRun({ code, stderr, stdout }));
  });
}

test("builds a minimal no-auth environment for the production server", () => {
  const environment = buildProductionChildEnvironment({
    PATH: "/usr/local/bin:/usr/bin",
    HOME: "/home/tester",
    LANG: "en_US.UTF-8",
    TMPDIR: "/tmp",
    DATABASE_URL: "postgresql://production.example/voya",
    VOYA_APP_URL: "https://app.voya.example",
    SUPABASE_ACCESS_TOKEN: "production-access-token",
    SUPABASE_PROJECT_REF: "production-project",
    SUPABASE_SERVICE_ROLE_KEY: "production-service-role",
    NEXT_PUBLIC_SUPABASE_URL: "https://production.supabase.co",
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "production-public-key",
    UNRELATED_SECRET: "must-not-cross-process-boundary",
  });

  assert.deepEqual(
    Object.keys(environment).sort(),
    [
      "HOME",
      "LANG",
      "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
      "NEXT_PUBLIC_SUPABASE_URL",
      "NODE_ENV",
      "PATH",
      "TMPDIR",
      "VOYA_APP_URL",
    ],
  );
  assert.equal(environment.NEXT_PUBLIC_SUPABASE_URL, "https://build-check.supabase.co");
  assert.equal(environment.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, "build-check-key");
  assert.equal(environment.NODE_ENV, "production");
  assert.equal(environment.DATABASE_URL, undefined);
  assert.equal(environment.VOYA_APP_URL, "https://app.build-check.example");
  assert.equal(environment.SUPABASE_ACCESS_TOKEN, undefined);
  assert.equal(environment.SUPABASE_PROJECT_REF, undefined);
  assert.equal(environment.SUPABASE_SERVICE_ROLE_KEY, undefined);
  assert.equal(environment.UNRELATED_SECRET, undefined);
});

test("accepts only root loopback HTTP origins", () => {
  assert.equal(
    assertLoopbackOrigin("http://127.0.0.1:3200").origin,
    "http://127.0.0.1:3200",
  );

  for (const value of [
    "https://127.0.0.1:3200",
    "http://app.voya.example",
    "http://127.0.0.1:3200/path",
    "http://127.0.0.1:3200/?query",
    "http://user:password@127.0.0.1:3200",
  ]) {
    assert.throws(() => assertLoopbackOrigin(value), /loopback HTTP origin/);
  }
});

test("rejects prerendered and shared-cache protected responses", () => {
  assert.doesNotThrow(() => assertRequestTimeResponse(new Response(null, {
    headers: { "cache-control": "private, no-store" },
  }), "workspace response"));

  for (const headers of [
    { "x-nextjs-prerender": "1" },
    { "x-nextjs-cache": "HIT" },
    { "cache-control": "private, S-MAXAGE=60" },
  ]) {
    assert.throws(
      () => assertRequestTimeResponse(new Response(null, { headers }), "workspace response"),
      /prerendered|shared Next\.js cache|shared-cache storage/,
    );
  }
});

test("requires a nonce CSP and baseline browser security headers", () => {
  const headers = new Headers({
    "content-security-policy": "default-src 'self'; script-src 'self' 'nonce-abc123' 'strict-dynamic'; frame-ancestors 'none'",
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "referrer-policy": "strict-origin-when-cross-origin",
  });
  assert.doesNotThrow(() => assertProductionSecurityHeaders(new Response(null, { headers }), "response"));
  headers.set("content-security-policy", "script-src 'self' 'unsafe-inline'");
  assert.throws(() => assertProductionSecurityHeaders(new Response(null, { headers }), "response"), /nonce-based CSP/);
});

test("rejects a static nonce-protected route", () => {
  assert.throws(
    () => productionRendering.assertRequestTimeResponse(
      new Response(null, { headers: { "x-nextjs-prerender": "1" } }),
      "sign-in response",
    ),
    /prerendered/,
  );
});

test("creates a disposable runtime where a source .env.local is absent and cannot load", async () => {
  const sourceRoot = await mkdtemp(join(tmpdir(), "voya-production-auth-source-"));
  let runtime;
  try {
    await mkdir(join(sourceRoot, ".next"));
    await mkdir(join(sourceRoot, "public"));
    await writeFile(join(sourceRoot, "package.json"), "{\"private\":true}\n");
    await writeFile(join(sourceRoot, "public", "health.txt"), "ok\n");
    await writeFile(join(sourceRoot, ".env.local"), "VOYA_SOURCE_ENV_SENTINEL=must-not-load\n");
    await symlink(resolve("node_modules"), join(sourceRoot, "node_modules"), "dir");

    runtime = await createProductionRuntimeRoot({ sourceRoot });

    assert.deepEqual(
      await readdir(runtime.root),
      [".next", "node_modules", "package.json", "public"],
    );
    await assert.rejects(access(join(runtime.root, ".env.local")));

    const probe = await runNode(
      [
        "--input-type=module",
        "--eval",
        'import nextEnv from "@next/env"; nextEnv.loadEnvConfig(process.cwd()); process.stdout.write(process.env.VOYA_SOURCE_ENV_SENTINEL ?? "absent");',
      ],
      { cwd: runtime.root, env: { PATH: process.env.PATH } },
    );
    assert.equal(probe.code, 0, probe.stderr);
    assert.equal(probe.stdout, "absent");

    await runtime.cleanup();
    await assert.rejects(access(runtime.root));
    runtime = undefined;
  } finally {
    await runtime?.cleanup();
    await rm(sourceRoot, { force: true, recursive: true });
  }
});
