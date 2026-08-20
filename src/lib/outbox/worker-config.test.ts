import { describe, expect, it } from "vitest";
import { authorizeOutboxWorkerRequest, readOutboxWorkerConfig } from "./worker-config";

const environment = {
  SUPABASE_URL: "https://project.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "server-only",
  OUTBOX_WORKER_SECRET: "worker-secret",
  VOYA_APP_URL: "https://app.example.test",
  OUTBOX_PAYLOAD_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString("base64"),
  RESEND_ENABLED: "true",
  RESEND_API_KEY: "re_test_secret",
  RESEND_FROM: "Voya OS <noreply@example.test>",
  WHATSAPP_OUTBOUND_ENABLED: "true",
  HUMAN_HANDOFF_APPROVED: "true",
  META_WHATSAPP_ACCESS_TOKEN: "meta-secret",
  META_GRAPH_API_VERSION: "v21.0",
};

describe("outbox worker configuration", () => {
  it("requires server-only runtime credentials and exposes only bounded flags", () => {
    const config = readOutboxWorkerConfig(environment);

    expect(config).toMatchObject({
      supabaseUrl: "https://project.supabase.co",
      workerSecret: "worker-secret",
      emailEnabled: true,
      whatsappEnabled: true,
      resendApiKey: "re_test_secret",
      metaWhatsAppAccessToken: "meta-secret",
    });
    expect(config).not.toHaveProperty("NEXT_PUBLIC");
  });

  it("does not authorize missing, malformed, or wrong worker credentials", () => {
    expect(authorizeOutboxWorkerRequest("Bearer worker-secret", "worker-secret")).toBe(true);
    expect(authorizeOutboxWorkerRequest("worker-secret", "worker-secret")).toBe(false);
    expect(authorizeOutboxWorkerRequest("Bearer wrong", "worker-secret")).toBe(false);
    expect(authorizeOutboxWorkerRequest(null, "worker-secret")).toBe(false);
    expect(authorizeOutboxWorkerRequest("Bearer worker-secret", "")).toBe(false);
  });

  it("fails closed when an enabled provider has no key", () => {
    expect(() => readOutboxWorkerConfig({ ...environment, RESEND_API_KEY: "" })).toThrow("RESEND_API_KEY");
    expect(() => readOutboxWorkerConfig({ ...environment, WHATSAPP_OUTBOUND_ENABLED: "false", META_WHATSAPP_ACCESS_TOKEN: "" })).not.toThrow();
  });
});
