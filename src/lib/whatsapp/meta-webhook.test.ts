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
      messageType: "text",
      bodyText: "مرحبا",
      providerMediaId: null,
      mediaMimeTypeHint: null,
      caption: null,
      receivedAt: null,
    }]);
    expect(parseInboundWhatsAppEvents({ entry: [{ changes: [{ value: { metadata: { phone_number_id: "x" }, messages: [{ id: "m", from: "p", type: "image" }] } }] }] })).toEqual([]);
  });

  test("extracts bounded image metadata and an optional caption", () => {
    expect(parseInboundWhatsAppEvents({
      entry: [{
        changes: [{
          field: "messages",
          value: {
            metadata: { phone_number_id: "channel-1" },
            messages: [{
              id: "wamid-image-1",
              from: "+201001234567",
              type: "image",
              timestamp: "1700000000",
              image: { id: "media-1", mime_type: "image/jpeg", caption: "واجهة العقار" },
            }],
          },
        }],
      }],
    })).toEqual([{
      provider: "meta_cloud",
      externalChannelId: "channel-1",
      externalConversationKey: "+201001234567",
      eventKey: "wamid-image-1",
      senderPhone: "+201001234567",
      messageType: "image",
      bodyText: null,
      providerMediaId: "media-1",
      mediaMimeTypeHint: "image/jpeg",
      caption: "واجهة العقار",
      receivedAt: "2023-11-14T22:13:20.000Z",
    }]);
  });

  test("bounds untrusted fields and never returns raw payloads", () => {
    expect(parseInboundWhatsAppEvents({ entry: [{ changes: [{ value: { metadata: { phone_number_id: "x" }, messages: [{ id: "m", from: "p", type: "text", text: { body: "x".repeat(4097) } }] } }] }] })).toEqual([]);
  });
});
