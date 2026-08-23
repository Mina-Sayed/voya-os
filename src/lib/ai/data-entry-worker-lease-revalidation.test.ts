import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const workerSource = readFileSync("supabase/functions/outbox-dispatch/index.ts", "utf8");
const recoveryMigration = readFileSync("supabase/migrations/20260823010000_harden_ai_data_entry_recovery.sql", "utf8");

describe("AI data-entry provider lease revalidation", () => {
  test("renews the current event lease after image loading and before the Gemini request", () => {
    const imageLoad = workerSource.indexOf("const { imageParts, inputIds } = await loadDataEntryImageParts");
    const leaseRenewal = workerSource.indexOf('rpc("renew_ai_data_entry_event_lease_v1"', imageLoad);
    const providerCall = workerSource.indexOf("provider.generate({ ...request, imageParts })", imageLoad);

    expect(imageLoad).toBeGreaterThanOrEqual(0);
    expect(leaseRenewal).toBeGreaterThan(imageLoad);
    expect(providerCall).toBeGreaterThan(leaseRenewal);
  });

  test("keeps event lease renewal behind the trusted worker boundary", () => {
    expect(recoveryMigration).toContain("CREATE OR REPLACE FUNCTION public.renew_ai_data_entry_event_lease_v1");
    expect(recoveryMigration).toContain("AND event.state = 'processing'");
    expect(recoveryMigration).toContain("AND event.locked_by = p_worker_id");
    expect(recoveryMigration).toContain("AND event.locked_until > timezone('utc', now())");
    expect(recoveryMigration).toContain("FROM PUBLIC, anon, authenticated");
    expect(recoveryMigration).toContain("TO voya_outbox_worker, service_role");
  });
});
