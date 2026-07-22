import { execFileSync, spawn } from "node:child_process";
import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const databaseUrl = process.env.DATABASE_URL;

if (process.env.VOYA_DB_TEST !== "1" || !databaseUrl) {
  throw new Error("Refusing database test: set VOYA_DB_TEST=1 and an explicit DATABASE_URL.");
}

const parsedUrl = new URL(databaseUrl);
const allowedHosts = new Set(["127.0.0.1", "localhost", "::1"]);

if (!allowedHosts.has(parsedUrl.hostname) || !parsedUrl.pathname.endsWith("_test")) {
  throw new Error("Refusing database test: use a local database whose name ends in _test.");
}

const password = decodeURIComponent(parsedUrl.password);
parsedUrl.password = "";
const safeConnectionUrl = parsedUrl.toString();
const projectRoot = fileURLToPath(new URL("../", import.meta.url));
const executePsql = (args) => {
  execFileSync("psql", [safeConnectionUrl, "-v", "ON_ERROR_STOP=1", ...args], {
    cwd: projectRoot,
    env: { ...process.env, PGPASSWORD: password },
    stdio: "inherit",
  });
};

const executePsqlAsync = (sql) => new Promise((resolve, reject) => {
  const child = spawn("psql", [safeConnectionUrl, "-v", "ON_ERROR_STOP=1", "-c", sql], {
    cwd: projectRoot,
    env: { ...process.env, PGPASSWORD: password },
  });
  let stderr = "";

  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  child.on("error", reject);
  child.on("close", (code) => {
    if (code === 0) {
      resolve();
      return;
    }
    reject(new Error(`Concurrent occupancy writer failed with exit code ${code}: ${stderr}`));
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

executePsql(["-c", "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"]);
executePsql(["-f", "supabase/tests/bootstrap_auth.sql"]);
for (const migration of readdirSync("supabase/migrations").filter((file) => file.endsWith(".sql")).sort()) {
  executePsql(["-f", `supabase/migrations/${migration}`]);
}
executePsql(["-f", "supabase/tests/tenancy_booking_foundation.sql"]);
executePsql(["-f", "supabase/tests/governance_foundation.sql"]);
executePsql(["-f", "supabase/tests/property_availability_foundation.sql"]);
executePsql(["-f", "supabase/tests/booking_occupancy_concurrency.sql"]);
executePsql(["-f", "supabase/tests/booking_draft_command.sql"]);
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
executePsql(["-f", "supabase/tests/outbox_foundation.sql"]);
await runOccupancyRace();
