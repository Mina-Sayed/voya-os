import { execFileSync, spawn } from "node:child_process";
import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const databaseUrl = process.env.DATABASE_URL;

if (process.env.VOYA_DB_TEST !== "1" || !databaseUrl) {
  throw new Error("Refusing database test: set VOYA_DB_TEST=1 and an explicit DATABASE_URL.");
}

const parsedUrl = new URL(databaseUrl);
const allowedHosts = new Set(["127.0.0.1", "localhost", "::1"]);

if (
  !allowedHosts.has(parsedUrl.hostname)
  || !parsedUrl.pathname.endsWith("_test")
  || parsedUrl.search
  || parsedUrl.hash
) {
  throw new Error("Refusing database test: use a local database whose name ends in _test and has no URI parameters.");
}

const password = decodeURIComponent(parsedUrl.password);
parsedUrl.password = "";
const safeConnectionUrl = parsedUrl.toString();
const projectRoot = fileURLToPath(new URL("../", import.meta.url));
const localPsqlEnvironment = () => {
  const environment = Object.fromEntries(
    Object.entries(process.env).filter(([key]) => !key.startsWith("PG")),
  );
  environment.PGPASSWORD = password;
  return environment;
};
const executePsql = (args) => {
  execFileSync("psql", [safeConnectionUrl, "-v", "ON_ERROR_STOP=1", ...args], {
    cwd: projectRoot,
    env: localPsqlEnvironment(),
    stdio: "inherit",
  });
};

const executePsqlAsync = (sql, failureLabel) => new Promise((resolve, reject) => {
  const child = spawn("psql", [safeConnectionUrl, "-v", "ON_ERROR_STOP=1", "-Atq", "-c", sql], {
    cwd: projectRoot,
    env: localPsqlEnvironment(),
  });
  let stdout = "";
  let stderr = "";

  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  child.on("error", reject);
  child.on("close", (code) => {
    if (code === 0) {
      resolve(stdout.trim());
      return;
    }
    reject(new Error(`${failureLabel} failed with exit code ${code}: ${stderr}`));
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
  `, "Concurrent booking occupancy writer");

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
  `, "Concurrent availability occupancy writer");

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
    { cwd: projectRoot, env: localPsqlEnvironment(), encoding: "utf8" },
  ).trim();

  if (committedOccupancy !== "1") {
    throw new Error(`Expected one committed race occupancy record, received ${committedOccupancy}.`);
  }
};

const commandActor = "77777777-7777-7777-7777-777777777777";
const commandOrganization = "dddddddd-dddd-dddd-dddd-dddddddddddd";
const commandClient = "dddddddd-0000-0000-0000-000000000002";
const commandConversation = "dddddddd-0000-0000-0000-000000000004";

const runCommandIdempotencyRace = async (name, sql) => {
  const invocation = `
    SET request.jwt.claim.sub = '${commandActor}';
    SET ROLE authenticated;
    ${sql}
  `;
  const [first, second] = await Promise.all([
    executePsqlAsync(invocation, `Concurrent ${name} writer`),
    executePsqlAsync(invocation, `Concurrent ${name} writer`),
  ]);

  if (!first || first !== second) {
    throw new Error(`Expected concurrent ${name} retries to return one winner, received ${first} and ${second}.`);
  }
};

const runCommandIdempotencyRaces = async () => {
  await runCommandIdempotencyRace("CRM contact", `
    SELECT public.create_crm_contact_method(
      '${commandOrganization}', 'phone', '+201000000000', 'Guest phone',
      NULL, '${commandClient}', 'race-contact', NULL
    );
  `);
  await runCommandIdempotencyRace("WhatsApp message", `
    SELECT public.create_whatsapp_message(
      '${commandOrganization}', '${commandConversation}',
      'Concurrent message retry', 'race-message', NULL
    );
  `);
  await runCommandIdempotencyRace("AI run", `
    SELECT public.create_ai_run_request(
      '${commandOrganization}', 'manager', 'Concurrent AI retry', 'race-ai-run', NULL
    );
  `);
  await runCommandIdempotencyRace("operations task", `
    SELECT public.create_operations_task(
      '${commandOrganization}', 'reliability.race', 'Concurrent task retry',
      NULL, NULL, NULL, NULL, 'race-task', NULL
    );
  `);
  await runCommandIdempotencyRace("transport request", `
    SELECT public.create_transport_request(
      '${commandOrganization}', 'airport_transfer', 'Concurrent guest',
      'Airport', 'Voya property', TIMESTAMPTZ '2027-05-02 10:00:00+00',
      2, NULL, NULL, NULL, 'race-transport', NULL
    );
  `);

  executePsql(["-c", `
    DO $$
    BEGIN
      IF (SELECT count(*) FROM public.crm_contact_methods WHERE organization_id = '${commandOrganization}' AND idempotency_key = 'race-contact') <> 1
        OR (SELECT count(*) FROM public.whatsapp_message_events WHERE organization_id = '${commandOrganization}' AND idempotency_key = 'race-message') <> 1
        OR (SELECT count(*) FROM public.ai_runs WHERE organization_id = '${commandOrganization}' AND idempotency_key = 'race-ai-run') <> 1
        OR (SELECT count(*) FROM public.operations_tasks WHERE organization_id = '${commandOrganization}' AND idempotency_key = 'race-task') <> 1
        OR (SELECT count(*) FROM public.transport_requests WHERE organization_id = '${commandOrganization}' AND idempotency_key = 'race-transport') <> 1 THEN
        RAISE EXCEPTION 'concurrent idempotency retries did not persist one winner per command';
      END IF;

      IF (SELECT count(*) FROM public.audit_events WHERE organization_id = '${commandOrganization}' AND action = 'crm.contact_method.created' AND resource_id IN (SELECT id FROM public.crm_contact_methods WHERE idempotency_key = 'race-contact')) <> 1
        OR (SELECT count(*) FROM public.audit_events WHERE organization_id = '${commandOrganization}' AND action = 'whatsapp.message.queued' AND resource_id IN (SELECT id FROM public.whatsapp_message_events WHERE idempotency_key = 'race-message')) <> 1
        OR (SELECT count(*) FROM public.audit_events WHERE organization_id = '${commandOrganization}' AND action = 'ai.run.requested' AND resource_id IN (SELECT id FROM public.ai_runs WHERE idempotency_key = 'race-ai-run')) <> 1
        OR (SELECT count(*) FROM public.audit_events WHERE organization_id = '${commandOrganization}' AND action = 'operations.task.created' AND resource_id IN (SELECT id FROM public.operations_tasks WHERE idempotency_key = 'race-task')) <> 1
        OR (SELECT count(*) FROM public.audit_events WHERE organization_id = '${commandOrganization}' AND action = 'transport.request.created' AND resource_id IN (SELECT id FROM public.transport_requests WHERE idempotency_key = 'race-transport')) <> 1 THEN
        RAISE EXCEPTION 'concurrent idempotency retries emitted duplicate or missing audit evidence';
      END IF;
    END;
    $$;
  `]);
};

executePsql(["-c", "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"]);
executePsql(["-f", "supabase/tests/bootstrap_auth.sql"]);
for (const migration of readdirSync("supabase/migrations").filter((file) => file.endsWith(".sql")).sort()) {
  executePsql(["--single-transaction", "-f", `supabase/migrations/${migration}`]);
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
executePsql(["-f", "supabase/tests/auth_rate_limit_policy.sql"]);
executePsql(["-f", "supabase/tests/auth_bootstrap_security.sql"]);
executePsql(["-f", "supabase/tests/command_idempotency.sql"]);
await runCommandIdempotencyRaces();
await runOccupancyRace();
