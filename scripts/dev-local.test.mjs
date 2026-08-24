import test from "node:test";
import assert from "node:assert/strict";
import {
  buildLocalDevelopmentEnvironment,
  ensureLocalSupabaseReady,
  readLocalSupabaseStatus,
} from "./dev-local.mjs";

const localStatusJson = JSON.stringify({
  API_URL: "http://127.0.0.1:55321",
  ANON_KEY: "local-publishable-key",
  SERVICE_ROLE_KEY: "local-service-role-key",
});

test("reads only the dedicated local Supabase status", () => {
  assert.deepEqual(
    readLocalSupabaseStatus({ run: () => localStatusJson }),
    {
      apiUrl: "http://127.0.0.1:55321",
      publishableKey: "local-publishable-key",
      serviceRoleKey: "local-service-role-key",
    },
  );
});

test("builds server-only local development configuration", () => {
  const environment = buildLocalDevelopmentEnvironment(
    { PATH: "/bin", HOME: "/tmp", VOYA_APP_URL: "http://127.0.0.1:3102" },
    {
      apiUrl: "http://127.0.0.1:55321",
      publishableKey: "local-publishable-key",
      serviceRoleKey: "local-service-role-key",
    },
  );

  assert.equal(environment.NEXT_PUBLIC_SUPABASE_URL, "http://127.0.0.1:55321");
  assert.equal(environment.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, "local-publishable-key");
  assert.equal(environment.SUPABASE_SERVICE_ROLE_KEY, "local-service-role-key");
  assert.match(environment.AUTH_RATE_LIMIT_HMAC_SECRET, /^[0-9a-f]{64}$/u);
  assert.match(environment.OUTBOX_PAYLOAD_ENCRYPTION_KEY, /^[0-9a-f]{64}$/u);
  assert.equal(environment.VOYA_AUTH_E2E_LOCAL, "1");
  assert.equal(environment.NODE_ENV, "development");
  assert.equal(environment.GEMINI_API_KEY, undefined);
});

test("rejects a non-local Supabase endpoint", () => {
  assert.throws(
    () => readLocalSupabaseStatus({ run: () => JSON.stringify({ API_URL: "https://remote.example", ANON_KEY: "key", SERVICE_ROLE_KEY: "secret" }) }),
    /Local Supabase must run/,
  );
});

test("starts Supabase, applies pending migrations, and waits for Auth readiness", async () => {
  const commands = [];
  const statusJson = JSON.stringify({
    API_URL: "http://127.0.0.1:55321",
    ANON_KEY: "local-publishable-key",
    SERVICE_ROLE_KEY: "local-service-role-key",
  });
  let healthCalls = 0;

  const status = await ensureLocalSupabaseReady({
    run: (args) => {
      commands.push(args);
      return args[0] === "status" ? statusJson : "";
    },
    fetchImpl: async () => {
      healthCalls += 1;
      if (healthCalls === 1) throw new Error("socket not ready");
      return new Response("ok", { status: 200 });
    },
    sleep: async () => {},
    timeoutMs: 1_000,
    intervalMs: 1,
  });

  assert.deepEqual(commands, [
    ["start"],
    ["migration", "up", "--local"],
    ["status", "-o", "json"],
  ]);
  assert.equal(healthCalls, 2);
  assert.equal(status.apiUrl, "http://127.0.0.1:55321");
});

test("reports actionable migration drift instead of starting an incomplete app", async () => {
  const driftError = Object.assign(new Error("supabase migration failed"), {
    stderr: "Remote migration versions not found in local migrations directory.",
  });

  await assert.rejects(
    () => ensureLocalSupabaseReady({
      run: (args) => {
        if (args[0] === "migration") throw driftError;
        return "";
      },
      fetchImpl: async () => new Response("ok", { status: 200 }),
      sleep: async () => {},
    }),
    /migration history is out of sync.*supabase db reset --local --no-seed/iu,
  );
});
