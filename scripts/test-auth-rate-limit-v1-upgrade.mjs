import { execFileSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const databaseUrl = process.env.DATABASE_URL;

if (process.env.VOYA_DB_TEST !== "1" || !databaseUrl) {
  throw new Error("Refusing auth V1 upgrade test: set VOYA_DB_TEST=1 and DATABASE_URL.");
}

const parsedUrl = new URL(databaseUrl);
const allowedHosts = new Set(["127.0.0.1", "localhost", "::1"]);
if (!allowedHosts.has(parsedUrl.hostname)) {
  throw new Error("Refusing auth V1 upgrade test: DATABASE_URL must be loopback-only.");
}

const password = decodeURIComponent(parsedUrl.password);
const projectRoot = fileURLToPath(new URL("../", import.meta.url));
const upgradeDatabaseName = "voya_auth_v1_upgrade_test";

const maintenanceUrl = new URL(databaseUrl);
maintenanceUrl.pathname = "/postgres";
maintenanceUrl.password = "";

const upgradeUrl = new URL(databaseUrl);
upgradeUrl.pathname = `/${upgradeDatabaseName}`;
upgradeUrl.password = "";

const runPsql = (connectionUrl, args, options = {}) => execFileSync(
  "psql",
  [connectionUrl.toString(), "-v", "ON_ERROR_STOP=1", ...args],
  {
    cwd: projectRoot,
    env: { ...process.env, PGPASSWORD: password },
    stdio: options.capture ? ["ignore", "pipe", "pipe"] : "inherit",
    encoding: options.capture ? "utf8" : undefined,
  },
);

const resetUpgradeDatabase = () => {
  runPsql(maintenanceUrl, ["-c", `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${upgradeDatabaseName}' AND pid <> pg_backend_pid();`]);
  runPsql(maintenanceUrl, ["-c", `DROP DATABASE IF EXISTS \"${upgradeDatabaseName}\";`]);
  runPsql(maintenanceUrl, ["-c", `CREATE DATABASE \"${upgradeDatabaseName}\";`]);
};

const dropUpgradeDatabase = () => {
  runPsql(maintenanceUrl, ["-c", `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${upgradeDatabaseName}' AND pid <> pg_backend_pid();`]);
  runPsql(maintenanceUrl, ["-c", `DROP DATABASE IF EXISTS \"${upgradeDatabaseName}\";`]);
};

const v1OnboardingMigration = "20260812013630_organization_onboarding_team_auth.sql";
const v1RateLimitMigration = "20260812014148_auth_rate_limit_v1_scopes.sql";

try {
  resetUpgradeDatabase();
  runPsql(upgradeUrl, ["-f", "supabase/tests/bootstrap_auth.sql"]);
  runPsql(upgradeUrl, ["-c", "DROP EXTENSION IF EXISTS pgcrypto CASCADE; CREATE SCHEMA IF NOT EXISTS extensions; CREATE EXTENSION pgcrypto WITH SCHEMA extensions;"]);

  const migrationFiles = readdirSync("supabase/migrations")
    .filter((file) => file.endsWith(".sql"))
    .sort();

  const baselineMigrations = migrationFiles.filter((file) => file <= v1OnboardingMigration);
  for (const migration of baselineMigrations) {
    runPsql(upgradeUrl, ["--single-transaction", "-f", `supabase/migrations/${migration}`]);
  }

  runPsql(upgradeUrl, ["-c", `
    INSERT INTO public.auth_rate_limit_buckets (
      key_hash, scope, window_started_at, attempt_count, updated_at
    ) VALUES (
      repeat('9', 64), 'magic_link', clock_timestamp(), 2, clock_timestamp()
    );
  `]);

  const v1BoundaryMigrations = migrationFiles.filter(
    (file) => file > v1OnboardingMigration && file <= v1RateLimitMigration,
  );
  for (const migration of v1BoundaryMigrations) {
    runPsql(upgradeUrl, ["--single-transaction", "-f", `supabase/migrations/${migration}`]);
  }

  const legacyRows = runPsql(
    upgradeUrl,
    ["-At", "-c", "SELECT count(*) FROM public.auth_rate_limit_buckets WHERE scope = 'magic_link';"],
    { capture: true },
  ).trim();
  if (legacyRows !== "0") {
    throw new Error(`Expected V1 upgrade to retire legacy magic-link rate-limit rows, found ${legacyRows}.`);
  }

  runPsql(upgradeUrl, ["-c", `
    DO $$
    BEGIN
      BEGIN
        PERFORM public.consume_auth_rate_limit('magic_link', repeat('a', 64));
        RAISE EXCEPTION 'removed magic-link scope was accepted after V1 upgrade';
      EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
      END;
    END;
    $$;
  `]);
} finally {
  dropUpgradeDatabase();
}
