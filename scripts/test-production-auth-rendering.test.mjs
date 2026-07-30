import assert from "node:assert/strict";
import test from "node:test";
import {
  assertLoopbackOrigin,
  assertRequestTimeResponse,
  buildProductionChildEnvironment,
} from "./test-production-auth-rendering.mjs";

test("builds a minimal synthetic environment for the production server", () => {
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
    ],
  );
  assert.equal(environment.NEXT_PUBLIC_SUPABASE_URL, "https://example.supabase.co");
  assert.equal(environment.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, "synthetic-public-key");
  assert.equal(environment.NODE_ENV, "production");
  assert.equal(environment.DATABASE_URL, undefined);
  assert.equal(environment.VOYA_APP_URL, undefined);
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
