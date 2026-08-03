import { createHmac } from "node:crypto";
import { describe, expect, test } from "vitest";
import { parseInboundWhatsAppEvents, verifyMetaWebhookSignature } from "./meta-webhook";

const payload = JSON.stringify({
  object: "whatsapp_business_account",
  entry: [{ changes: [{ field: "messages", value: { metadata: { phone_number_id: "sandbox-channel-a" }, messages: [{ id: "wamid-1", from: "+201001234567", type: "text", text: { body: "مرحبا" } }] } }] }],
});

describe("Meta WhatsApp webhook boundary", () => {
  test("accepts only a constant-time HMAC signature for the raw body", () => {
    const signature = createHmac("sha256", "app-secret").update(payload).digest("hex");
    expect(verifyMetaWebhookSignature(payload, `sha256=${signature}`, "app-secret")).toBe(true);
    expect(verifyMetaWebhookSignature(`${payload} `, `sha256=${signature}`, "app-secret")).toBe(false);
    expect(verifyMetaWebhookSignature(payload, "sha256=bad", "app-secret")).toBe(false);
  });

  test("extracts text events and ignores status/media payloads", () => {
    expect(parseInboundWhatsAppEvents(JSON.parse(payload))).toEqual([{
      provider: "meta_cloud",
      externalChannelId: "sandbox-channel-a",
      externalConversationKey: "+201001234567",
      eventKey: "wamid-1",
      senderPhone: "+201001234567",
      bodyText: "مرحبا",
    }]);
    expect(parseInboundWhatsAppEvents({ entry: [{ changes: [{ value: { metadata: { phone_number_id: "x" }, messages: [{ id: "m", from: "p", type: "image" }] } }] }] })).toEqual([]);
  });

  test("bounds untrusted fields and never returns raw payloads", () => {
    expect(parseInboundWhatsAppEvents({ entry: [{ changes: [{ value: { metadata: { phone_number_id: "x" }, messages: [{ id: "m", from: "p", type: "text", text: { body: "x".repeat(4097) } }] } }] }] })).toEqual([]);
  });
});
