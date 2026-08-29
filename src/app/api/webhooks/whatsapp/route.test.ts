import { createHmac } from "node:crypto";
import { NextRequest } from "next/server";
import { afterEach, describe, expect, test, vi } from "vitest";

const runtime = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServiceRoleSupabaseClient: vi.fn(() => ({ rpc: runtime.rpc })),
}));

import { GET, POST } from "./route";

const payload = JSON.stringify({
  entry: [{ changes: [{ field: "messages", value: { metadata: { phone_number_id: "sandbox-channel-a" }, messages: [{ id: "wamid-1", from: "+201001234567", type: "text", timestamp: "1700000000", text: { body: "hello" } }] } }] }],
});

afterEach(() => {
  vi.clearAllMocks();
  delete process.env.WHATSAPP_VERIFY_TOKEN;
  delete process.env.META_WHATSAPP_APP_SECRET;
  delete process.env.SUPABASE_SERVICE_ROLE_KEY;
});

describe("WhatsApp webhook route", () => {
  test("answers Meta verification only with the configured token", async () => {
    process.env.WHATSAPP_VERIFY_TOKEN = "verify-token";
    const response = await GET(new NextRequest("https://voya.test/api/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=verify-token&hub.challenge=123"));
    expect(response.status).toBe(200);
    await expect(response.text()).resolves.toBe("123");
  });

  test("rejects unsigned payloads before creating a Supabase client", async () => {
    process.env.META_WHATSAPP_APP_SECRET = "app-secret";
    const response = await POST(new NextRequest("https://voya.test/api/webhooks/whatsapp", { method: "POST", body: payload }));
    expect(response.status).toBe(401);
    expect(runtime.rpc).not.toHaveBeenCalled();
  });

  test("accepts a signed text event and queues only inbound ingestion", async () => {
    process.env.META_WHATSAPP_APP_SECRET = "app-secret";
    process.env.SUPABASE_SERVICE_ROLE_KEY = "server-only";
    runtime.rpc.mockResolvedValue({ data: "message-id", error: null });
    const signature = createHmac("sha256", "app-secret").update(payload).digest("hex");
    const response = await POST(new NextRequest("https://voya.test/api/webhooks/whatsapp", {
      method: "POST",
      headers: { "x-hub-signature-256": `sha256=${signature}` },
      body: payload,
    }));
    expect(response.status).toBe(202);
    await expect(response.json()).resolves.toEqual({ accepted: true, events: 1 });
    expect(runtime.rpc).toHaveBeenCalledWith("ingest_whatsapp_webhook_event_v1", {
      p_provider: "meta_cloud",
      p_external_channel_id: "sandbox-channel-a",
      p_external_conversation_key: "+201001234567",
      p_event_key: "wamid-1",
      p_sender_phone: "+201001234567",
      p_message_type: "text",
      p_body_text: "hello",
      p_provider_media_id: null,
      p_media_mime_hint: null,
      p_caption: null,
      p_received_at: "2023-11-14T22:13:20.000Z",
    });
    expect(JSON.stringify(runtime.rpc.mock.calls)).not.toContain("server-only");
  });

  test("rejects an oversized body before reading or verifying provider content", async () => {
    process.env.META_WHATSAPP_APP_SECRET = "app-secret";
    const response = await POST(new NextRequest("https://voya.test/api/webhooks/whatsapp", {
      method: "POST",
      body: "x".repeat(256 * 1024 + 1),
    }));

    expect(response.status).toBe(413);
    await expect(response.json()).resolves.toEqual({ error: "payload_too_large" });
    expect(runtime.rpc).not.toHaveBeenCalled();
  });
});
