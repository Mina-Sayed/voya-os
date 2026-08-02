import { execFileSync, spawn } from "node:child_process";
import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const databaseUrl = process.env.DATABASE_URL;

if (process.env.VOYA_DB_TEST !== "1" || !databaseUrl) {
  throw new Error("Refusing database test: set VOYA_DB_TEST=1 and an explicit DATABASE_URL.");
}

const parsedUrl = new URL(databaseUrl);
const allowedHosts = new Set(["127.0.0.1", "localhost", "::1"]);
const databaseName = decodeURIComponent(parsedUrl.pathname.replace(/^\/+/, ""));

if (
  !allowedHosts.has(parsedUrl.hostname)
  || !/^[A-Za-z_][A-Za-z0-9_]*_test$/u.test(databaseName)
  || parsedUrl.search
  || parsedUrl.hash
) {
  throw new Error("Refusing database test: use a local database whose name matches *_test.");
}

const password = decodeURIComponent(parsedUrl.password);
parsedUrl.password = "";
const safeConnectionUrl = parsedUrl.toString();
const maintenanceUrl = new URL(databaseUrl);
maintenanceUrl.pathname = "/postgres";
maintenanceUrl.password = "";
const safeMaintenanceConnectionUrl = maintenanceUrl.toString();
const projectRoot = fileURLToPath(new URL("../", import.meta.url));
const executePsqlConnection = (connectionUrl, args) => {
  execFileSync("psql", [connectionUrl, "-v", "ON_ERROR_STOP=1", ...args], {
    cwd: projectRoot,
    env: { ...process.env, PGPASSWORD: password },
    stdio: "inherit",
  });
};
const executePsql = (args) => executePsqlConnection(safeConnectionUrl, args);

const ensureDisposableDatabase = () => {
  const exists = execFileSync(
    "psql",
    [safeMaintenanceConnectionUrl, "-At", "-v", "ON_ERROR_STOP=1", "-c", `SELECT 1 FROM pg_database WHERE datname = '${databaseName}';`],
    { cwd: projectRoot, env: { ...process.env, PGPASSWORD: password }, encoding: "utf8" },
  ).trim();
  if (exists === "1") return;
  executePsqlConnection(safeMaintenanceConnectionUrl, ["-c", `CREATE DATABASE \"${databaseName}\";`]);
};

const executePsqlAsync = (sql) => new Promise((resolve, reject) => {
  const child = spawn("psql", [safeConnectionUrl, "-At", "-v", "ON_ERROR_STOP=1", "-c", sql], {
    cwd: projectRoot,
    env: { ...process.env, PGPASSWORD: password },
  });
  let stderr = "";
  let stdout = "";

  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  child.on("error", reject);
  child.on("close", (code) => {
    if (code === 0) {
      resolve(stdout);
      return;
    }
    reject(new Error(`Concurrent database writer failed with exit code ${code}: ${stderr}`));
  });
});

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

const runOccupancyRace = async () => {
  const bookingWriter = executePsqlAsync(`
    BEGIN;
    INSERT INTO public.bookings (
      organization_id, property_id, client_id, status, check_in, check_out
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000002',
      'confirmed', DATE '2027-03-10', DATE '2027-03-15'
    );
    SELECT pg_sleep(1);
    COMMIT;
  `);

  await delay(100);

  const blockWriter = executePsqlAsync(`
    BEGIN;
    INSERT INTO public.availability_blocks (
      organization_id, property_id, start_date, end_date, block_type
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      DATE '2027-03-12', DATE '2027-03-14', 'maintenance'
    );
    COMMIT;
  `);

  const results = await Promise.allSettled([bookingWriter, blockWriter]);
  const committedWriters = results.filter((result) => result.status === "fulfilled");

  if (committedWriters.length !== 1) {
    throw new Error("Expected exactly one conflicting occupancy writer to commit.");
  }

  const committedOccupancy = execFileSync(
    "psql",
    [
      safeConnectionUrl,
      "-At",
      "-c",
      `SELECT count(*)
       FROM public.property_occupancies
       WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
         AND property_id = 'aaaaaaaa-0000-0000-0000-000000000001'
         AND daterange(start_date, end_date, '[)') && daterange(DATE '2027-03-12', DATE '2027-03-14', '[)');`,
    ],
    { cwd: projectRoot, env: { ...process.env, PGPASSWORD: password }, encoding: "utf8" },
  ).trim();

  if (committedOccupancy !== "1") {
    throw new Error(`Expected one committed race occupancy record, received ${committedOccupancy}.`);
  }
};

const runOutboxClaimRace = async () => {
  executePsql(["-c", `
    UPDATE public.outbox_events
    SET available_at = now() + interval '1 day',
        locked_until = CASE WHEN state = 'processing' THEN now() + interval '1 day' ELSE NULL END
    WHERE state IN ('pending', 'retry_wait', 'processing');

    INSERT INTO public.outbox_events (
      organization_id, event_type, schema_version, dedupe_key, payload
    ) VALUES
      ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'notification.prepare', 1, 'outbox-race-a', '{}'::jsonb),
      ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'notification.prepare', 1, 'outbox-race-b', '{}'::jsonb);
  `]);

  const workerA = executePsqlAsync(`
    BEGIN;
    SELECT count(*) FROM public.claim_outbox_events('outbox-race-worker-a', 1, 60);
    SELECT pg_sleep(1);
    COMMIT;
  `);

  await delay(100);

  const workerB = executePsqlAsync(`
    BEGIN;
    SET LOCAL lock_timeout = '250ms';
    SELECT count(*) FROM public.claim_outbox_events('outbox-race-worker-b', 1, 60);
    COMMIT;
  `);

  const [workerAOutput, workerBOutput] = await Promise.all([workerA, workerB]);
  const claimCount = (output) => output.split(/\r?\n/).find((line) => line === "0" || line === "1");

  if (claimCount(workerAOutput) !== "1" || claimCount(workerBOutput) !== "1") {
    throw new Error("Expected each concurrent outbox worker to claim one distinct event.");
  }

  const claimedEvents = execFileSync(
    "psql",
    [
      safeConnectionUrl,
      "-At",
      "-c",
      `SELECT
         count(*) FILTER (WHERE locked_by = 'outbox-race-worker-a' AND attempts = 1)::text
         || ':' || count(*) FILTER (WHERE locked_by = 'outbox-race-worker-b' AND attempts = 1)::text
         || ':' || count(DISTINCT locked_by)::text
       FROM public.outbox_events
       WHERE dedupe_key IN ('outbox-race-a', 'outbox-race-b')
         AND state = 'processing';`,
    ],
    { cwd: projectRoot, env: { ...process.env, PGPASSWORD: password }, encoding: "utf8" },
  ).trim();

  if (claimedEvents !== "1:1:2") {
    throw new Error(`Expected two non-duplicated concurrent outbox claims, received ${claimedEvents}.`);
  }
};

const introduceOutboxWorkerDrift = () => {
  executePsql(["-c", `
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'voya_outbox_worker') THEN
        CREATE ROLE voya_outbox_worker NOLOGIN NOINHERIT;
      END IF;
    END;
    $$;
    ALTER ROLE voya_outbox_worker LOGIN INHERIT;
    GRANT EXECUTE ON FUNCTION public.claim_outbox_events(text, integer, integer) TO PUBLIC, anon, authenticated;
    GRANT SELECT ON TABLE public.outbox_events TO anon, authenticated, voya_outbox_worker;
  `]);
};

ensureDisposableDatabase();
executePsql(["-c", "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"]);
executePsql(["-f", "supabase/tests/bootstrap_auth.sql"]);
// Supabase installs pgcrypto in its protected extensions schema. Recreate that
// layout in the disposable harness so SECURITY DEFINER functions are tested
// against the same schema-qualified extension boundary.
executePsql(["-c", "DROP EXTENSION IF EXISTS pgcrypto CASCADE; CREATE SCHEMA IF NOT EXISTS extensions; CREATE EXTENSION pgcrypto WITH SCHEMA extensions;"]);
for (const migration of readdirSync("supabase/migrations").filter((file) => file.endsWith(".sql")).sort()) {
  if (migration === "20260722001900_outbox_lease_recovery.sql") {
    introduceOutboxWorkerDrift();
  }
  executePsql(["-f", `supabase/migrations/${migration}`]);
}
executePsql(["-f", "supabase/tests/tenancy_booking_foundation.sql"]);
executePsql(["-f", "supabase/tests/governance_foundation.sql"]);
executePsql(["-f", "supabase/tests/property_availability_foundation.sql"]);
executePsql(["-f", "supabase/tests/booking_occupancy_concurrency.sql"]);
executePsql(["-f", "supabase/tests/booking_draft_command.sql"]);
executePsql(["-f", "supabase/tests/booking_draft_read.sql"]);
executePsql(["-f", "supabase/tests/booking_lifecycle.sql"]);
executePsql(["-f", "supabase/tests/property_owner_command.sql"]);
executePsql(["-f", "supabase/tests/property_owner_read.sql"]);
executePsql(["-f", "supabase/tests/property_command.sql"]);
executePsql(["-f", "supabase/tests/property_read.sql"]);
executePsql(["-f", "supabase/tests/client_command_read.sql"]);
executePsql(["-f", "supabase/tests/lead_registry_command_read.sql"]);
executePsql(["-f", "supabase/tests/availability_block_command_read.sql"]);
executePsql(["-f", "supabase/tests/audit_activity_read.sql"]);
executePsql(["-f", "supabase/tests/approval_request_read.sql"]);
executePsql(["-f", "supabase/tests/notification_foundation.sql"]);
executePsql(["-f", "supabase/tests/auth_rate_limit.sql"]);
executePsql(["-f", "supabase/tests/outbox_foundation.sql"]);
executePsql(["-f", "supabase/tests/crm_whatsapp_inbox.sql"]);
executePsql(["-f", "supabase/tests/ai_agent_center.sql"]);
executePsql(["-f", "supabase/tests/operations_tasks.sql"]);
executePsql(["-f", "supabase/tests/transport_operations.sql"]);
await runOutboxClaimRace();
await runOccupancyRace();
