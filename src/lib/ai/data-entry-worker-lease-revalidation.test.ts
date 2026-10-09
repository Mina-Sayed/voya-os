import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";
import { dispatchOutboxEvent } from "../outbox/dispatch-contract";

const workerSource = readFileSync("supabase/functions/outbox-dispatch/index.ts", "utf8");
const recoveryMigration = readFileSync("supabase/migrations/20260823010000_harden_ai_data_entry_recovery.sql", "utf8");
const outboxLeaseMigration = readFileSync("supabase/migrations/20260821022646_grant_outbox_lifecycle_to_service_role.sql", "utf8");

describe("provider lease revalidation", () => {
  test("renews the data-entry event lease after image loading and before the Gemini request", () => {
    const imageLoad = workerSource.indexOf("const { imageParts, inputIds } = await loadDataEntryImageParts");
    const leaseRenewal = workerSource.indexOf("renewAiEventLease(client, row.id, workerId)", imageLoad);
    const providerCall = workerSource.indexOf("provider.generate({ ...request, imageParts })", imageLoad);

    expect(imageLoad).toBeGreaterThanOrEqual(0);
    expect(leaseRenewal).toBeGreaterThan(imageLoad);
    expect(providerCall).toBeGreaterThan(leaseRenewal);
  });

  test("renews ordinary AI events immediately before their Gemini request too", () => {
    const ordinaryRequest = workerSource.indexOf("const request = buildAiGenerationRequest");
    const leaseRenewal = workerSource.indexOf("renewAiEventLease(client, row.id, workerId)", ordinaryRequest);
    const providerCall = workerSource.indexOf("provider.generate(request)", ordinaryRequest);

    expect(ordinaryRequest).toBeGreaterThanOrEqual(0);
    expect(leaseRenewal).toBeGreaterThan(ordinaryRequest);
    expect(providerCall).toBeGreaterThan(leaseRenewal);
  });

  test("renews invitation email delivery immediately before calling Resend", () => {
    const callback = workerSource.indexOf("sendEmail: async (request) =>");
    const leaseRenewal = workerSource.indexOf("renewOutboxDeliveryLease(client, row.id, workerId)", callback);
    const providerCall = workerSource.indexOf("resend.send(request)", callback);

    expect(callback).toBeGreaterThanOrEqual(0);
    expect(leaseRenewal).toBeGreaterThan(callback);
    expect(providerCall).toBeGreaterThan(leaseRenewal);
  });

  test("renews a live WhatsApp lease immediately before calling Meta", async () => {
    const calls: string[] = [];
    const result = await dispatchOutboxEvent({
      id: "lease-order-whatsapp-event",
      event_type: "whatsapp.message.send_requested",
      schema_version: 1,
      attempts: 1,
      payload: {
        provider: "meta_cloud",
        providerChannelId: "meta-phone-lease-test",
        recipientPhone: "+201001234567",
        body: "مرحبا",
      },
    }, {
      emailEnabled: false,
      whatsappEnabled: true,
      openWaEnabled: false,
      applicationUrl: "https://app.example.test",
      sendEmail: async () => ({ kind: "permanent" }),
      renewWhatsAppLease: async () => {
        calls.push("renew");
        return true;
      },
      sendWhatsApp: async (request) => {
        calls.push(request.provider === "meta_cloud" ? "meta" : "openwa");
        return { kind: "delivered", providerMessageId: "wamid-lease-order-test" };
      },
    });

    expect(result).toMatchObject({ outcome: "completed", providerMessageId: "wamid-lease-order-test" });
    expect(calls).toEqual(["renew", "meta"]);
  });

  test("keeps AI event lease renewal behind the trusted worker boundary", () => {
    expect(recoveryMigration).toContain("CREATE OR REPLACE FUNCTION public.renew_ai_event_lease_v1");
    expect(recoveryMigration).toContain("AND event.state = 'processing'");
    expect(recoveryMigration).toContain("AND event.locked_by = p_worker_id");
    expect(recoveryMigration).toContain("AND event.locked_until > timezone('utc', now())");
    expect(recoveryMigration).toContain("AND run.status = 'running'");
    expect(recoveryMigration).toContain("AND draft.status = 'extracting'");
    expect(recoveryMigration).toContain("FROM PUBLIC, anon, authenticated");
    expect(recoveryMigration).toContain("TO voya_outbox_worker, service_role");
  });

  test("keeps email and WhatsApp lease renewal worker/service-only", () => {
    expect(outboxLeaseMigration).toContain("CREATE OR REPLACE FUNCTION public.renew_outbox_delivery_lease_v1");
    expect(outboxLeaseMigration).toContain("'organization.invitation.send_requested'");
    expect(outboxLeaseMigration).toContain("'member.invitation.resent'");
    expect(outboxLeaseMigration).toContain("'whatsapp.message.send_requested'");
    expect(outboxLeaseMigration).toContain("AND event.state = 'processing'");
    expect(outboxLeaseMigration).toContain("AND event.locked_by = p_worker_id");
    expect(outboxLeaseMigration).toContain("AND event.locked_until > timezone('utc', now())");
    expect(outboxLeaseMigration).toContain("REVOKE ALL ON FUNCTION public.renew_outbox_delivery_lease_v1(uuid,text,integer) FROM PUBLIC, anon, authenticated");
    expect(outboxLeaseMigration).toContain("GRANT EXECUTE ON FUNCTION public.renew_outbox_delivery_lease_v1(uuid,text,integer) TO voya_outbox_worker, service_role");
  });
});
