import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
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
       FROM (
         SELECT booking.id
         FROM public.bookings AS booking
         WHERE booking.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
           AND booking.property_id = 'aaaaaaaa-0000-0000-0000-000000000001'
           AND booking.status = 'confirmed'
           AND daterange(booking.check_in, booking.check_out, '[)') && daterange(DATE '2027-03-12', DATE '2027-03-14', '[)')
         UNION ALL
         SELECT block.id
         FROM public.availability_blocks AS block
         WHERE block.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
           AND block.property_id = 'aaaaaaaa-0000-0000-0000-000000000001'
           AND daterange(block.start_date, block.end_date, '[)') && daterange(DATE '2027-03-10', DATE '2027-03-15', '[)')
       ) AS committed;`,
    ],
    { cwd: projectRoot, env: { ...process.env, PGPASSWORD: password }, encoding: "utf8" },
  ).trim();

  if (committedOccupancy !== "1") {
    throw new Error("Expected exactly one overlapping occupancy writer to persist.");
  }
};

const runTransportAllocationRace = async () => {
  executePsql(["-c", `
    DO $$
    DECLARE
      v_actor uuid := (
        SELECT id FROM public.organization_memberships
        WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
          AND user_id = '11111111-1111-1111-1111-111111111111'
      );
    BEGIN
      INSERT INTO public.fleet_vehicles (
        id, organization_id, display_name, vehicle_type, registration_code, passenger_capacity, idempotency_key
      ) VALUES (
        'aaaaaaaa-0000-0000-0000-000000000341', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'Transport race vehicle', 'sedan', 'RACE-341', 4, 'transport-race-vehicle-341'
      ) ON CONFLICT (id) DO NOTHING;
      INSERT INTO public.fleet_drivers (
        id, organization_id, display_name, phone_e164, idempotency_key
      ) VALUES
        ('aaaaaaaa-0000-0000-0000-000000000351', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Driver Race A', '+201000000351', 'transport-race-driver-351'),
        ('aaaaaaaa-0000-0000-0000-000000000352', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Driver Race B', '+201000000352', 'transport-race-driver-352')
      ON CONFLICT (id) DO NOTHING;
      INSERT INTO public.transport_requests (
        id, organization_id, request_type, status, guest_label,
        pickup_location, dropoff_location, pickup_at, return_at,
        passenger_count, created_by_membership_id, idempotency_key
      ) VALUES
        ('aaaaaaaa-0000-0000-0000-000000000361', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
         'car_rental', 'requested', 'Transport race A', 'Airport', 'Hotel',
         '2043-01-01 10:00:00+00', '2043-01-01 14:00:00+00', 2, v_actor, 'transport-race-361'),
        ('aaaaaaaa-0000-0000-0000-000000000362', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
         'car_rental', 'requested', 'Transport race B', 'Airport', 'Hotel',
         '2043-01-01 11:00:00+00', '2043-01-01 15:00:00+00', 2, v_actor, 'transport-race-362')
      ON CONFLICT (id) DO NOTHING;
    END;
    $$;
  `]);

  const assign = (requestId, driverId, holdLock) => executePsqlAsync(`
    SET ROLE authenticated;
    SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
    BEGIN;
    SELECT public.assign_transport_request(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      '${requestId}',
      'aaaaaaaa-0000-0000-0000-000000000341',
      '${driverId}', NULL
    );
    ${holdLock ? "SELECT pg_sleep(1);" : ""}
    COMMIT;
  `);

  const firstWriter = assign(
    "aaaaaaaa-0000-0000-0000-000000000361",
    "aaaaaaaa-0000-0000-0000-000000000351",
    true,
  );
  await delay(100);
  const secondWriter = assign(
    "aaaaaaaa-0000-0000-0000-000000000362",
    "aaaaaaaa-0000-0000-0000-000000000352",
    false,
  );

  const results = await Promise.allSettled([firstWriter, secondWriter]);
  if (results.filter((result) => result.status === "fulfilled").length !== 1) {
    throw new Error("Expected exactly one overlapping transport allocation writer to commit.");
  }

  const allocationState = execFileSync(
    "psql",
    [
      safeConnectionUrl,
      "-At",
      "-c",
      `SELECT
         count(*) FILTER (WHERE status = 'assigned' AND vehicle_id = 'aaaaaaaa-0000-0000-0000-000000000341')::text
         || ':' || count(*) FILTER (WHERE status = 'requested' AND vehicle_id IS NULL)::text
       FROM public.transport_requests
       WHERE id IN (
         'aaaaaaaa-0000-0000-0000-000000000361',
         'aaaaaaaa-0000-0000-0000-000000000362'
       );`,
    ],
    { cwd: projectRoot, env: { ...process.env, PGPASSWORD: password }, encoding: "utf8" },
  ).trim();

  if (allocationState !== "1:1") {
    throw new Error(`Expected one assigned and one untouched transport request, received ${allocationState}.`);
  }
};

const runBookingConfirmationRace = async () => {
  executePsql(["-c", `
    DO $$
    DECLARE
      v_requester uuid := (
        SELECT id FROM public.organization_memberships
        WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
          AND user_id = '55555555-5555-5555-5555-555555555555'
      );
      v_snapshot jsonb := jsonb_build_object(
        'booking_id', 'aaaaaaaa-0000-0000-0000-000000000241'::uuid,
        'property_id', 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
        'client_id', 'aaaaaaaa-0000-0000-0000-000000000002'::uuid,
        'check_in', DATE '2044-01-01', 'check_out', DATE '2044-01-03',
        'status', 'draft'
      );
    BEGIN
      INSERT INTO public.bookings (
        id, organization_id, property_id, client_id, status, check_in, check_out
      ) VALUES (
        'aaaaaaaa-0000-0000-0000-000000000241',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'aaaaaaaa-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000002',
        'pending_approval', DATE '2044-01-01', DATE '2044-01-03'
      );
      INSERT INTO public.approval_requests (
        id, organization_id, resource_type, resource_id, proposed_action,
        proposal_snapshot, snapshot_hash, requester_membership_id, status, expires_at
      ) VALUES (
        'aaaaaaaa-0000-0000-0000-000000000251',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'booking',
        'aaaaaaaa-0000-0000-0000-000000000241', 'booking.confirm',
        v_snapshot, encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'),
        v_requester, 'approved', clock_timestamp() + interval '1 hour'
      );
    END;
    $$;
  `]);

  const confirm = (holdLock) => executePsqlAsync(`
    SET ROLE authenticated;
    SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
    BEGIN;
    SELECT public.confirm_booking(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000241',
      'booking-confirm-race-241', NULL
    );
    ${holdLock ? "SELECT pg_sleep(1);" : ""}
    COMMIT;
  `);

  const firstWriter = confirm(true);
  await delay(100);
  const secondWriter = confirm(false);
  await Promise.all([firstWriter, secondWriter]);

  const confirmationState = execFileSync(
    "psql",
    [
      safeConnectionUrl,
      "-At",
      "-c",
      `SELECT booking.status || ':' || approval.status || ':'
         || (SELECT count(*) FROM public.booking_command_idempotency
             WHERE organization_id = booking.organization_id
               AND command_name = 'booking.confirm'
               AND booking_id = booking.id)::text || ':'
         || (SELECT count(*) FROM public.audit_events
             WHERE organization_id = booking.organization_id
               AND resource_id = booking.id
               AND action = 'booking.confirmed')::text || ':'
         || (SELECT count(*) FROM public.outbox_events
             WHERE organization_id = booking.organization_id
               AND dedupe_key = 'booking-confirmed:' || booking.id::text)::text
       FROM public.bookings AS booking
       JOIN public.approval_requests AS approval
         ON approval.organization_id = booking.organization_id
        AND approval.id = 'aaaaaaaa-0000-0000-0000-000000000251'
       WHERE booking.id = 'aaaaaaaa-0000-0000-0000-000000000241';`,
    ],
    { cwd: projectRoot, env: { ...process.env, PGPASSWORD: password }, encoding: "utf8" },
  ).trim();

  if (confirmationState !== "confirmed:executed:1:1:1") {
    throw new Error(`Expected one idempotent booking confirmation, received ${confirmationState}.`);
  }
};

const runAiIdempotencyRace = async () => {
  const idempotencyKey = `ai-idempotency-race-${randomUUID()}`;
  const requestA = randomUUID();
  const requestB = randomUUID();
  const createRequest = (requestId, holdLock) => executePsqlAsync(`
    SET ROLE authenticated;
    SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
    BEGIN;
    SELECT public.create_ai_run_request(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'copilot', 'concurrent copilot request', '${idempotencyKey}', '${requestId}'
    );
    ${holdLock ? "SELECT pg_sleep(1);" : ""}
    COMMIT;
  `);

  const firstWriter = createRequest(requestA, true);
  await delay(100);
  const secondWriter = createRequest(requestB, false);
  const results = await Promise.allSettled([firstWriter, secondWriter]);
  if (results.some((result) => result.status !== "fulfilled")) {
    throw new Error("Concurrent AI requests with one idempotency key must both resolve successfully.");
  }

  const requestCount = execFileSync(
    "psql",
    [safeConnectionUrl, "-At", "-c", `SELECT count(*) FROM public.ai_runs WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND idempotency_key = '${idempotencyKey}';`],
    { cwd: projectRoot, env: { ...process.env, PGPASSWORD: password }, encoding: "utf8" },
  ).trim();
  if (requestCount !== "1") {
    throw new Error(`Concurrent AI idempotency must persist one run, received ${requestCount}.`);
  }
};

const runAiDataEntryDraftIdempotencyRace = async () => {
  const idempotencyKey = `ai-data-entry-draft-race-${randomUUID()}`;
  const requestA = randomUUID();
  const requestB = randomUUID();
  const createDraft = (requestId, holdLock) => executePsqlAsync(`
    SET ROLE authenticated;
    SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
    SELECT set_config('request.jwt.claim.aal', 'aal2', false);
    BEGIN;
    SELECT public.create_ai_data_entry_draft_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'concurrent draft source', '${idempotencyKey}', '${requestId}'
    );
    ${holdLock ? "SELECT pg_sleep(1);" : ""}
    COMMIT;
  `);

  const firstWriter = createDraft(requestA, true);
  await delay(100);
  const secondWriter = createDraft(requestB, false);
  const results = await Promise.allSettled([firstWriter, secondWriter]);
  if (results.some((result) => result.status !== "fulfilled")) {
    throw new Error("Concurrent AI data-entry draft retries with one idempotency key must both resolve successfully.");
  }

  const draftState = execFileSync(
    "psql",
    [
      safeConnectionUrl,
      "-At",
      "-c",
      `SELECT count(*)::text || ':' || count(*) FILTER (WHERE source_text = 'concurrent draft source')::text
       FROM public.ai_data_entry_drafts
       WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
         AND idempotency_key = '${idempotencyKey}';`,
    ],
    { cwd: projectRoot, env: { ...process.env, PGPASSWORD: password }, encoding: "utf8" },
  ).trim();
  if (draftState !== "1:1") {
    throw new Error(`Concurrent AI data-entry draft retries must persist one matching draft, received ${draftState}.`);
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

const runOwnerRoleChangeRace = async () => {
  const organizationId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
  const firstOwner = "11111111-1111-1111-1111-111111111111";
  const secondOwner = "55555555-5555-5555-5555-555555555555";

  executePsql(["-c", `
    UPDATE public.organization_memberships
    SET role = 'owner', status = 'active'
    WHERE organization_id = '${organizationId}' AND user_id = '${secondOwner}';
  `]);

  const secondOwnerMembershipCount = execFileSync(
    "psql",
    [safeConnectionUrl, "-At", "-c", `SELECT count(*) FROM public.organization_memberships WHERE organization_id = '${organizationId}' AND user_id = '${secondOwner}';`],
    { cwd: projectRoot, env: { ...process.env, PGPASSWORD: password }, encoding: "utf8" },
  ).trim();
  if (secondOwnerMembershipCount !== "1") throw new Error("Expected the second owner fixture before running the concurrent role-change race.");

  const downgrade = (userId) => executePsqlAsync(`
    SET ROLE authenticated;
    SELECT set_config('request.jwt.claim.sub', '${userId}', false);
    BEGIN;
    SELECT public.change_organization_member_role(
      '${organizationId}',
      (SELECT id FROM public.organization_memberships
       WHERE organization_id = '${organizationId}' AND user_id = '${userId}'),
      'viewer', NULL
    );
    SELECT pg_sleep(1);
    COMMIT;
  `);

  const firstWriter = downgrade(firstOwner);
  await delay(100);
  const secondWriter = downgrade(secondOwner);
  const results = await Promise.allSettled([firstWriter, secondWriter]);

  if (results.filter((result) => result.status === "fulfilled").length !== 1
    || results.filter((result) => result.status === "rejected").length !== 1) {
    throw new Error("Expected exactly one concurrent owner downgrade to commit and one to be denied.");
  }

  const ownerCount = execFileSync(
    "psql",
    [safeConnectionUrl, "-At", "-c", `SELECT count(*) FROM public.organization_memberships WHERE organization_id = '${organizationId}' AND role = 'owner' AND status = 'active';`],
    { cwd: projectRoot, env: { ...process.env, PGPASSWORD: password }, encoding: "utf8" },
  ).trim();
  if (ownerCount !== "1") throw new Error(`Expected one active owner after the concurrent race, received ${ownerCount}.`);

  executePsql(["-c", `
    UPDATE public.organization_memberships
    SET role = 'manager', status = 'active'
    WHERE organization_id = '${organizationId}' AND user_id = '${secondOwner}';
    UPDATE public.organization_memberships
    SET role = 'owner', status = 'active'
    WHERE organization_id = '${organizationId}' AND user_id = '${firstOwner}';
  `]);
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

const remediationMigration = "20260803085546_production_security_remediation.sql";
const postgrestGrantMigration = "20260803090304_revoke_postgrest_table_grants.sql";
const advisorHardeningMigration = "20260803090755_harden_runtime_security_advisors.sql";
const passwordSignupMigration = "20260803092522_password_signup_rate_limit.sql";
const compatibilityMigration = "20260810182752_harden_auth_rate_limit_policy.sql";
const runtimeReliabilityMigration = "20260810182809_harden_auth_bootstrap_and_command_reliability.sql";
const v1OnboardingMigration = "20260812013630_organization_onboarding_team_auth.sql";
const v1RateLimitMigration = "20260812014148_auth_rate_limit_v1_scopes.sql";
const v1CommercialBookingMigration = "20260812015419_commercial_booking_v1.sql";
const v1TeamCommandsMigration = "20260812020242_team_member_commands_v1.sql";
const v1PropertyInventoryMigration = "20260813000100_property_inventory_v1.sql";
const v1CrmMigration = "20260813000200_crm_v1.sql";
const v1OutboxDispatchMigration = "20260813013307_outbox_dispatch_v1.sql";
const v1CompletionMigration = "20260813014953_v1_completion_ai_tasks_observability.sql";
const v1ReconfirmationTaskMigration = "20260816224540_v1_reconfirmation_task.sql";
const v1TransportNotificationMigration = "20260817000100_v1_transport_assignment_notifications.sql";
const v1SystemHealthMigration = "20260817000200_v1_system_health_and_overdue.sql";
const v1AuditFiltersMigration = "20260817000300_v1_audit_activity_filters.sql";
const v1ApprovalNotificationsMigration = "20260817000400_v1_approval_decision_notifications.sql";
const v1DeliveryFailureNotificationsMigration = "20260817000500_v1_delivery_failure_notifications.sql";
const v1BookingClientHardeningMigration = "20260817000600_harden_booking_client_and_webhook_limits.sql";
const aiCopilotMigration = "20260820000100_ai_copilot_readonly.sql";
const developSecurityHardeningMigration = "20260824000100_develop_security_integrity_hardening.sql";
const outboxServiceRoleGrantMigration = "20260821022646_grant_outbox_lifecycle_to_service_role.sql";
const aiDataEntryMigration = "20260822121522_ai_data_entry_drafts.sql";
const aiDataEntryHardeningMigration = "20260822193000_harden_ai_data_entry_confirmation.sql";
const aiDataEntryRecoveryMigration = "20260823010000_harden_ai_data_entry_recovery.sql";
const aiDataEntryCleanupMigration = "20260823203000_harden_ai_data_entry_cleanup.sql";
const whatsappAiAgentPhase1Migration = "20260827153809_whatsapp_ai_agent_phase1.sql";
const fleetIdempotencyMigration = "20260903000100_fleet_create_idempotency.sql";
const pr8FinalHardeningMigrations = [
  "20260824040000_finalize_ai_data_entry_recovery.sql",
  "20260824041000_align_ai_data_entry_lock_order.sql",
  "20260824043000_archive_terminal_ai_data_entry_inputs.sql",
  "20260824192400_reject_expired_ai_data_entry_extraction.sql",
  "20260824230536_reject_whitespace_ai_data_entry_submission.sql",
  "20260825010000_apply_ai_data_entry_property_image_v1.sql",
];
const bookingReviewBoundaryMigrations = [
  "20260826010000_finalize_booking_amendment_review_boundaries.sql",
  "20260826011000_complete_booking_change_review_projection.sql",
  "20260827020000_list_executable_booking_changes_v1.sql",
];
const pr12ReviewHardeningMigrations = [
  "20260827010000_harden_ai_data_entry_review_findings.sql",
];
const postRemediationMigrations = new Set([
  remediationMigration,
  postgrestGrantMigration,
  advisorHardeningMigration,
  passwordSignupMigration,
  compatibilityMigration,
  runtimeReliabilityMigration,
  v1OnboardingMigration,
  v1RateLimitMigration,
  v1CommercialBookingMigration,
  v1TeamCommandsMigration,
  v1PropertyInventoryMigration,
  v1CrmMigration,
  v1OutboxDispatchMigration,
  v1CompletionMigration,
  v1ReconfirmationTaskMigration,
  v1TransportNotificationMigration,
  v1SystemHealthMigration,
  v1AuditFiltersMigration,
  v1ApprovalNotificationsMigration,
  v1DeliveryFailureNotificationsMigration,
  v1BookingClientHardeningMigration,
  aiCopilotMigration,
  outboxServiceRoleGrantMigration,
  aiDataEntryMigration,
  aiDataEntryHardeningMigration,
  aiDataEntryRecoveryMigration,
  aiDataEntryCleanupMigration,
  developSecurityHardeningMigration,
  whatsappAiAgentPhase1Migration,
  fleetIdempotencyMigration,
  ...pr8FinalHardeningMigrations,
  ...bookingReviewBoundaryMigrations,
  ...pr12ReviewHardeningMigrations,
]);
const migrations = readdirSync("supabase/migrations")
  .filter((file) => file.endsWith(".sql"))
  .sort();

if (migrations.length !== 62 + pr8FinalHardeningMigrations.length + bookingReviewBoundaryMigrations.length + pr12ReviewHardeningMigrations.length + 1
  || !migrations.includes("20260803070631_self_service_workspace_bootstrap.sql")
  || !migrations.includes(passwordSignupMigration)
  || !migrations.includes(compatibilityMigration)
  || !migrations.includes(runtimeReliabilityMigration)
  || !migrations.includes(aiDataEntryRecoveryMigration)
  || !migrations.includes(aiDataEntryCleanupMigration)
  || !migrations.includes(developSecurityHardeningMigration)
  || !migrations.includes(whatsappAiAgentPhase1Migration)
  || !migrations.includes(fleetIdempotencyMigration)
  || pr8FinalHardeningMigrations.some((migration) => !migrations.includes(migration))
  || bookingReviewBoundaryMigrations.some((migration) => !migrations.includes(migration))
  || pr12ReviewHardeningMigrations.some((migration) => !migrations.includes(migration))) {
  throw new Error("Expected the managed migration records plus forward compatibility and V1 migrations.");
}

const resetDisposableSchema = () => {
  executePsql(["-c", "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"]);
  executePsql(["-f", "supabase/tests/bootstrap_auth.sql"]);
  // Supabase installs pgcrypto in its protected extensions schema. Recreate
  // that layout so SECURITY DEFINER functions see the production boundary.
  executePsql(["-c", "DROP EXTENSION IF EXISTS pgcrypto CASCADE; CREATE SCHEMA IF NOT EXISTS extensions; CREATE EXTENSION pgcrypto WITH SCHEMA extensions;"]);
};

const applyMigrations = (migrationFiles) => {
  for (const migration of migrationFiles) {
    if (migration === "20260722001900_outbox_lease_recovery.sql") {
      introduceOutboxWorkerDrift();
    }
    executePsql(["--single-transaction", "-f", `supabase/migrations/${migration}`]);
  }
};

ensureDisposableDatabase();

// First prove a forward migration over the immediately preceding schema with
// tenant-consistent representative data. This state is then discarded.
resetDisposableSchema();
applyMigrations(migrations.filter((migration) => !postRemediationMigrations.has(migration)));
executePsql(["-f", "supabase/tests/tenancy_booking_foundation.sql"]);
executePsql(["-f", "supabase/tests/production_security_upgrade_fixture.sql"]);
executePsql(["-f", "supabase/tests/production_security_migration_preflight.sql"]);
executePsql(["--single-transaction", "-f", `supabase/migrations/${remediationMigration}`]);
executePsql(["--single-transaction", "-f", `supabase/migrations/${postgrestGrantMigration}`]);
executePsql(["--single-transaction", "-f", `supabase/migrations/${advisorHardeningMigration}`]);
// Reproduce the managed-only regression before applying the forward repair.
executePsql(["--single-transaction", "-f", `supabase/migrations/${passwordSignupMigration}`]);
executePsql(["-f", "supabase/tests/production_security_rate_limit_regression.sql"]);
executePsql(["--single-transaction", "-f", `supabase/migrations/${compatibilityMigration}`]);
executePsql(["--single-transaction", "-f", `supabase/migrations/${runtimeReliabilityMigration}`]);
executePsql(["-f", "supabase/tests/production_security_upgrade_assertions.sql"]);
executePsql(["-f", "supabase/tests/tenant_integrity_remediation.sql"]);

// Then prove a clean install and the complete integration/concurrency suite.
resetDisposableSchema();
applyMigrations(migrations);
executePsql(["-f", "supabase/tests/tenancy_booking_foundation.sql"]);
executePsql(["-f", "supabase/tests/governance_foundation.sql"]);
executePsql(["-f", "supabase/tests/self_service_workspace_bootstrap.sql"]);
executePsql(["-f", "supabase/tests/property_availability_foundation.sql"]);
executePsql(["-f", "supabase/tests/booking_occupancy_concurrency.sql"]);
executePsql(["-f", "supabase/tests/booking_draft_command.sql"]);
executePsql(["-f", "supabase/tests/booking_draft_read.sql"]);
executePsql(["-f", "supabase/tests/booking_lifecycle.sql"]);
executePsql(["-f", "supabase/tests/property_owner_command.sql"]);
executePsql(["-f", "supabase/tests/property_owner_read.sql"]);
executePsql(["-f", "supabase/tests/property_command.sql"]);
executePsql(["-f", "supabase/tests/property_read.sql"]);
executePsql(["-f", "supabase/tests/property_inventory_v1.sql"]);
executePsql(["-f", "supabase/tests/crm_v1.sql"]);
executePsql(["-f", "supabase/tests/client_command_read.sql"]);
executePsql(["-f", "supabase/tests/lead_registry_command_read.sql"]);
executePsql(["-f", "supabase/tests/availability_block_command_read.sql"]);
executePsql(["-f", "supabase/tests/audit_activity_read.sql"]);
executePsql(["-f", "supabase/tests/approval_request_read.sql"]);
executePsql(["-f", "supabase/tests/notification_foundation.sql"]);
executePsql(["-f", "supabase/tests/auth_rate_limit.sql"]);
executePsql(["-f", "supabase/tests/outbox_foundation.sql"]);
executePsql(["-f", "supabase/tests/crm_whatsapp_inbox.sql"]);
executePsql(["-f", "supabase/tests/outbox_dispatch_v1.sql"]);
executePsql(["-f", "supabase/tests/whatsapp_webhook.sql"]);
executePsql(["-f", "supabase/tests/ai_agent_center.sql"]);
executePsql(["-f", "supabase/tests/ai_copilot.sql"]);
executePsql(["-f", "supabase/tests/ai_data_entry.sql"]);
executePsql(["-f", "supabase/tests/ai_data_entry_recovery.sql"]);
executePsql(["-f", "supabase/tests/ai_data_entry_cleanup.sql"]);
executePsql(["-f", "supabase/tests/operations_tasks.sql"]);
executePsql(["-f", "supabase/tests/system_health.sql"]);
executePsql(["-f", "supabase/tests/audit_activity_filters.sql"]);
executePsql(["-f", "supabase/tests/transport_operations.sql"]);
executePsql(["-f", "supabase/tests/organization_onboarding_team.sql"]);
executePsql(["-f", "supabase/tests/commercial_booking_v1.sql"]);
executePsql(["-f", "supabase/tests/executable_booking_changes_v1.sql"]);
executePsql(["-f", "supabase/tests/reconfirmation_task.sql"]);
executePsql(["-f", "supabase/tests/approval_decision_notifications.sql"]);
executePsql(["-f", "supabase/tests/delivery_failure_notifications.sql"]);
executePsql(["-f", "supabase/tests/team_member_commands_v1.sql"]);
executePsql(["-f", "supabase/tests/tenant_integrity_remediation.sql"]);
executePsql(["-f", "supabase/tests/postgrest_table_grants.sql"]);
executePsql(["-f", "supabase/tests/develop_security_hardening.sql"]);
executePsql(["-f", "supabase/tests/whatsapp_ai_agent_phase1.sql"]);
await runTransportAllocationRace();
await runBookingConfirmationRace();
await runAiIdempotencyRace();
await runAiDataEntryDraftIdempotencyRace();
await runOutboxClaimRace();
await runOwnerRoleChangeRace();
await runOccupancyRace();
