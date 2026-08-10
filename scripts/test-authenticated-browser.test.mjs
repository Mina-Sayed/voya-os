import assert from "node:assert/strict";
import test from "node:test";
import * as authenticatedBrowserHarness from "./test-authenticated-browser.mjs";
import {
  assertDisposableLocalProject,
  assertLocalSupabaseStatus,
  assertLocalSupabaseUrl,
  assertSafeLocalSupabaseCommand,
  orchestrateAuthenticatedBrowser,
} from "./test-authenticated-browser.mjs";

const LOCAL_PROJECT_ID = "voya-os-auth-e2e";

test("accepts only loopback Supabase API URLs", () => {
  assert.equal(assertLocalSupabaseUrl("http://127.0.0.1:55321").hostname, "127.0.0.1");
  assert.equal(assertLocalSupabaseUrl("http://localhost:55321").hostname, "localhost");
  assert.equal(assertLocalSupabaseUrl("http://[::1]:55321").hostname, "[::1]");

  assert.throws(
    () => assertLocalSupabaseUrl("https://project.supabase.co"),
    /loopback/,
  );
  assert.throws(
    () => assertLocalSupabaseUrl("http://127.0.0.1:55321", { protocols: ["postgresql:"] }),
    /protocol/,
  );
});

test("requires the dedicated disposable local project identity", () => {
  assert.equal(
    assertDisposableLocalProject({
      projectId: LOCAL_PROJECT_ID,
      disposableAcknowledgement: "1",
    }),
    LOCAL_PROJECT_ID,
  );

  assert.throws(
    () => assertDisposableLocalProject({
      projectId: "voya-os",
      disposableAcknowledgement: "1",
    }),
    /dedicated local project/,
  );
  assert.throws(
    () => assertDisposableLocalProject({
      projectId: LOCAL_PROJECT_ID,
      disposableAcknowledgement: undefined,
    }),
    /VOYA_AUTH_E2E_DISPOSABLE=1/,
  );
});

test("rejects a status payload unless both API and database are loopback", () => {
  const localStatus = {
    API_URL: "http://127.0.0.1:55321",
    DB_URL: "postgresql://postgres:local-only@127.0.0.1:55322/postgres",
    ANON_KEY: "local-public-key",
    SERVICE_ROLE_KEY: "local-service-key",
  };

  assert.deepEqual(
    assertLocalSupabaseStatus(localStatus),
    {
      apiUrl: "http://127.0.0.1:55321",
      databaseUrl: "postgresql://postgres:local-only@127.0.0.1:55322/postgres",
      publishableKey: "local-public-key",
      serviceRoleKey: "local-service-key",
    },
  );

  assert.throws(
    () => assertLocalSupabaseStatus({
      ...localStatus,
      API_URL: "https://project.supabase.co",
    }),
    /loopback/,
  );
  assert.throws(
    () => assertLocalSupabaseStatus({
      ...localStatus,
      DB_URL: "postgresql://postgres:secret@db.example.com:5432/postgres",
    }),
    /loopback/,
  );
});

test("rejects loopback status endpoints outside the dedicated API and database identity", () => {
  const localStatus = {
    API_URL: "http://127.0.0.1:55321",
    DB_URL: "postgresql://postgres:local-only@127.0.0.1:55322/postgres",
    ANON_KEY: "local-public-key",
    SERVICE_ROLE_KEY: "local-service-key",
  };

  for (const [field, value] of [
    ["API_URL", "http://127.0.0.1:65421"],
    ["API_URL", "http://localhost:55321"],
    ["DB_URL", "postgresql://postgres:local-only@127.0.0.1:65422/postgres"],
    ["DB_URL", "postgresql://other:local-only@127.0.0.1:55322/postgres"],
    ["DB_URL", "postgresql://postgres:local-only@127.0.0.1:55322/other"],
  ]) {
    assert.throws(
      () => assertLocalSupabaseStatus({ ...localStatus, [field]: value }),
      /dedicated local/,
      `${field}=${value} must not be accepted as the disposable stack`,
    );
  }
});

test("prefers local anon and service-role JWTs when status also includes new API keys", () => {
  const status = assertLocalSupabaseStatus({
    API_URL: "http://127.0.0.1:55321",
    DB_URL: "postgresql://postgres:local-only@127.0.0.1:55322/postgres",
    ANON_KEY: "local-anon-jwt",
    PUBLISHABLE_KEY: "local-publishable-key",
    SERVICE_ROLE_KEY: "local-service-role-jwt",
    SECRET_KEY: "local-secret-key",
  });

  assert.equal(status.publishableKey, "local-anon-jwt");
  assert.equal(status.serviceRoleKey, "local-service-role-jwt");
});

test("permits only explicit local Supabase lifecycle commands", () => {
  assert.deepEqual(
    assertSafeLocalSupabaseCommand(["db", "reset", "--local", "--no-seed"]),
    ["db", "reset", "--local", "--no-seed"],
  );
  assert.deepEqual(
    assertSafeLocalSupabaseCommand(["start"]),
    ["start"],
  );

  assert.throws(
    () => assertSafeLocalSupabaseCommand(["db", "push", "--linked"]),
    /not permitted/,
  );
  assert.throws(
    () => assertSafeLocalSupabaseCommand(["db", "reset", "--linked"]),
    /not permitted/,
  );
  assert.throws(
    () => assertSafeLocalSupabaseCommand([
      "db",
      "reset",
      "--local",
      "--no-seed",
      "--workdir",
      "/tmp/other-project",
    ]),
    /not permitted/,
  );
  assert.throws(
    () => assertSafeLocalSupabaseCommand(["db", "reset", "--local", "--workdir", "."]),
    /not permitted/,
  );
});

test("builds every local lifecycle command through the pinned Supabase CLI", () => {
  assert.equal(typeof authenticatedBrowserHarness.buildLocalSupabaseInvocation, "function");
  assert.deepEqual(
    authenticatedBrowserHarness.buildLocalSupabaseInvocation(["status", "-o", "json"]),
    {
      command: "npx",
      args: ["--yes", "supabase@2.109.1", "status", "-o", "json"],
    },
  );
  assert.throws(
    () => authenticatedBrowserHarness.buildLocalSupabaseInvocation(["db", "push", "--linked"]),
    /not permitted/,
  );
});

test("builds a loopback-only psql invocation without exposing its password in arguments", () => {
  assert.equal(typeof authenticatedBrowserHarness.buildLocalPsqlInvocation, "function");
  const invocation = authenticatedBrowserHarness.buildLocalPsqlInvocation(
    "postgresql://postgres:local-database-password@127.0.0.1:55322/postgres",
  );

  assert.equal(invocation.command, "psql");
  assert.deepEqual(invocation.args, [
    "--host", "127.0.0.1",
    "--port", "55322",
    "--username", "postgres",
    "--dbname", "postgres",
    "--no-password",
    "--no-psqlrc",
    "--set", "ON_ERROR_STOP=1",
  ]);
  assert.equal(invocation.environment.PGPASSWORD, "local-database-password");
  assert.equal(invocation.args.join(" ").includes("local-database-password"), false);
  assert.throws(
    () => authenticatedBrowserHarness.buildLocalPsqlInvocation(
      "postgresql://postgres:remote-password@db.example.com:5432/postgres",
    ),
    /loopback/,
  );
  assert.throws(
    () => authenticatedBrowserHarness.buildLocalPsqlInvocation(
      "postgresql://postgres:local-password@127.0.0.1:65422/postgres",
    ),
    /dedicated local/,
  );
  assert.throws(
    () => authenticatedBrowserHarness.buildLocalPsqlInvocation(
      "postgresql://postgres:local-password@127.0.0.1:55322/other",
    ),
    /dedicated local/,
  );
});

test("builds a production Next server sequence instead of a development server", () => {
  assert.equal(
    typeof authenticatedBrowserHarness.buildIsolatedNextInvocations,
    "function",
  );
  const invocations = authenticatedBrowserHarness.buildIsolatedNextInvocations(
    "/workspace/voya-os",
  );

  assert.deepEqual(invocations.build.args.slice(1), ["build", "--webpack"]);
  assert.deepEqual(invocations.start.args.slice(1), [
    "start",
    "--hostname",
    "127.0.0.1",
    "--port",
    "3102",
  ]);
  assert.equal(
    [...invocations.build.args, ...invocations.start.args].includes("dev"),
    false,
  );
});

test("passes local public and server-only auth values to the isolated browser server", () => {
  assert.equal(
    typeof authenticatedBrowserHarness.buildPlaywrightEnvironment,
    "function",
  );
  const environment = authenticatedBrowserHarness.buildPlaywrightEnvironment(
    {
      PATH: "/usr/local/bin:/usr/bin",
      HOME: "/home/tester",
      LANG: "en_US.UTF-8",
      DATABASE_URL: "postgresql://production.example/voya",
      VOYA_APP_URL: "https://production.example",
      SUPABASE_ACCESS_TOKEN: "production-access-token",
      SUPABASE_PROJECT_REF: "production-project",
      SUPABASE_SERVICE_ROLE_KEY: "production-service-role",
      NEXT_PUBLIC_SUPABASE_URL: "https://production.supabase.co",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "production-public-key",
      UNRELATED_SECRET: "must-not-cross-process-boundary",
    },
    {
      apiUrl: "http://127.0.0.1:55321",
      databaseUrl: "postgresql://postgres:local-only@127.0.0.1:55322/postgres",
      publishableKey: "local-public-key",
      serviceRoleKey: "local-service-key",
    },
    {
      "single-membership": { email: "single@voya.invalid", password: "local-password" },
      "multi-membership": { email: "multi@voya.invalid", password: "local-password" },
      suspended: { email: "suspended@voya.invalid", password: "local-password" },
    },
  );

  assert.deepEqual(
    Object.keys(environment).sort(),
    [
      "HOME",
      "LANG",
      "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
      "NEXT_PUBLIC_SUPABASE_URL",
      "NEXT_PUBLIC_VOYA_AUTH_E2E_LOCAL",
      "PATH",
      "SUPABASE_SERVICE_ROLE_KEY",
      "VOYA_AUTH_E2E_APP_ORIGIN",
      "VOYA_AUTH_E2E_FIXTURES",
      "VOYA_AUTH_E2E_LOCAL",
    ],
  );
  assert.equal(environment.NEXT_PUBLIC_SUPABASE_URL, "http://127.0.0.1:55321");
  assert.equal(environment.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, "local-public-key");
  assert.equal(environment.SUPABASE_SERVICE_ROLE_KEY, "local-service-key");
  assert.equal(environment.DATABASE_URL, undefined);
  assert.equal(environment.VOYA_APP_URL, undefined);
  assert.equal(environment.UNRELATED_SECRET, undefined);
});

test("passes no fixture or ambient production values to the isolated Next server", () => {
  assert.equal(
    typeof authenticatedBrowserHarness.buildNextEnvironment,
    "function",
  );
  const environment = authenticatedBrowserHarness.buildNextEnvironment({
    PATH: "/usr/local/bin:/usr/bin",
    HOME: "/home/tester",
    TMPDIR: "/tmp",
    VOYA_AUTH_E2E_LOCAL: "1",
    VOYA_AUTH_E2E_APP_ORIGIN: "http://127.0.0.1:3102",
    VOYA_AUTH_E2E_FIXTURES: "{\"password\":\"must-not-reach-next\"}",
    NEXT_PUBLIC_SUPABASE_URL: "http://127.0.0.1:55321",
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "local-public-key",
    DATABASE_URL: "postgresql://production.example/voya",
    VOYA_APP_URL: "https://production.example",
    SUPABASE_PROJECT_REF: "production-project",
    SUPABASE_SERVICE_ROLE_KEY: "production-service-role",
  });

  assert.deepEqual(
    Object.keys(environment).sort(),
    [
      "HOME",
      "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
      "NEXT_PUBLIC_SUPABASE_URL",
      "NEXT_PUBLIC_VOYA_AUTH_E2E_LOCAL",
      "PATH",
      "SUPABASE_SERVICE_ROLE_KEY",
      "TMPDIR",
      "VOYA_AUTH_E2E_APP_ORIGIN",
      "VOYA_AUTH_E2E_LOCAL",
    ],
  );
  assert.equal(environment.VOYA_AUTH_E2E_FIXTURES, undefined);
  assert.equal(environment.DATABASE_URL, undefined);
  assert.equal(environment.VOYA_APP_URL, undefined);
  assert.equal(environment.SUPABASE_PROJECT_REF, undefined);
  assert.equal(environment.SUPABASE_SERVICE_ROLE_KEY, "production-service-role");
});

test("aborts before database reset, fixture creation, or Playwright when status is remote", async () => {
  const commands = [];
  let fixtureCreationAttempted = false;
  let playwrightAttempted = false;

  await assert.rejects(
    () => orchestrateAuthenticatedBrowser({
      environment: { VOYA_AUTH_E2E_DISPOSABLE: "1" },
      readProjectId: async () => LOCAL_PROJECT_ID,
      runSupabase: async (args) => {
        commands.push(args);
        return {
          stdout: JSON.stringify({
            API_URL: "https://project.supabase.co",
            DB_URL: "postgresql://postgres:secret@db.example.com:5432/postgres",
            ANON_KEY: "remote-public-key",
            SERVICE_ROLE_KEY: "remote-service-key",
          }),
        };
      },
      createFixtures: async () => {
        fixtureCreationAttempted = true;
        return { fixtures: {}, cleanup: async () => {} };
      },
      runPlaywright: async () => {
        playwrightAttempted = true;
      },
    }),
    /loopback/,
  );

  assert.deepEqual(commands, [["status", "-o", "json"]]);
  assert.equal(fixtureCreationAttempted, false);
  assert.equal(playwrightAttempted, false);
});

test("cleans fixtures and stops a stack it started when Playwright fails", async () => {
  const events = [];
  let statusAttempts = 0;
  const localStatus = {
    API_URL: "http://127.0.0.1:55321",
    DB_URL: "postgresql://postgres:local-only@127.0.0.1:55322/postgres",
    ANON_KEY: "local-public-key",
    SERVICE_ROLE_KEY: "local-service-key",
  };

  await assert.rejects(
    () => orchestrateAuthenticatedBrowser({
      environment: { VOYA_AUTH_E2E_DISPOSABLE: "1" },
      readProjectId: async () => LOCAL_PROJECT_ID,
      runSupabase: async (args) => {
        events.push(`supabase:${args.join(" ")}`);
        if (args[0] === "status" && statusAttempts++ === 0) {
          throw new Error("Local stack is not running.");
        }
        return { stdout: args[0] === "status" ? JSON.stringify(localStatus) : "" };
      },
      createFixtures: async (status) => {
        events.push(`fixtures:create:${status.apiUrl}`);
        return {
          fixtures: { synthetic: true },
          cleanup: async () => {
            events.push("fixtures:cleanup");
          },
        };
      },
      runPlaywright: async () => {
        events.push("playwright");
        throw new Error("Synthetic Playwright failure.");
      },
    }),
    /Synthetic Playwright failure/,
  );

  assert.deepEqual(events, [
    "supabase:status -o json",
    "supabase:start",
    "supabase:status -o json",
    "supabase:db reset --local --no-seed",
    "fixtures:create:http://127.0.0.1:55321",
    "playwright",
    "fixtures:cleanup",
    "supabase:stop",
  ]);
});

test("stops a partially started stack when Supabase start fails", async () => {
  const events = [];

  await assert.rejects(
    () => orchestrateAuthenticatedBrowser({
      environment: { VOYA_AUTH_E2E_DISPOSABLE: "1" },
      readProjectId: async () => LOCAL_PROJECT_ID,
      runSupabase: async (args) => {
        events.push(`supabase:${args.join(" ")}`);
        if (args[0] === "status") throw new Error("Local stack is not running.");
        if (args[0] === "start") throw new Error("Partial local stack startup failure.");
        return { stdout: "" };
      },
      createFixtures: async () => {
        throw new Error("Fixture creation must not run.");
      },
      runPlaywright: async () => {
        throw new Error("Playwright must not run.");
      },
    }),
    /Partial local stack startup failure/,
  );

  assert.deepEqual(events, [
    "supabase:status -o json",
    "supabase:start",
    "supabase:stop",
  ]);
});
