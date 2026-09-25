import { createHmac } from "node:crypto";
import { describe, expect, test } from "vitest";
import { parseOpenWaMessageEvent, verifyOpenWaSignature } from "./openwa-webhook";

const TEST_SECRET = "synthetic-openwa-webhook-test-secret";

type TestPayload = {
  event: string;
  timestamp: string;
  sessionId: string;
  idempotencyKey: string;
  deliveryId: string;
  data: Record<string, unknown>;
};

function payload(overrides: Partial<TestPayload> = {}): TestPayload {
  return {
    event: "message.received",
    timestamp: "2026-09-25T10:00:00.000Z",
    sessionId: "session-opaque-01",
    idempotencyKey: "msg_session-opaque-01_WA_IN_001",
    deliveryId: "delivery-001",
    data: {
      id: "WA_IN_001",
      from: "201001234567@c.us",
      to: "201599999999@c.us",
      chatId: "201001234567@c.us",
      body: "مرحبا",
      type: "text",
      timestamp: 1_700_000_000,
      fromMe: false,
      isGroup: false,
      kind: "individual",
      contact: { pushName: "Maha" },
    },
    ...overrides,
  };
}

function expectIgnored(value: unknown) {
  const result = parseOpenWaMessageEvent(value);
  expect(result).toEqual({ kind: "ignored" });
  expect(JSON.stringify(result)).not.toContain("PRIVATE_OPENWA_SENTINEL");
  expect(JSON.stringify(result)).not.toContain("PRIVATE_OPENWA_ID");
  expect(JSON.stringify(result)).not.toContain("PRIVATE_OPENWA_JID");
}

describe("OpenWA webhook signature", () => {
  test("verifies HMAC-SHA256 over the exact raw bytes", () => {
    const rawBytes = new TextEncoder().encode('{ "message": "مرحبا" }');
    const signature = `sha256=${createHmac("sha256", TEST_SECRET).update(rawBytes).digest("hex")}`;

    expect(verifyOpenWaSignature(rawBytes, signature, TEST_SECRET)).toBe(true);
    expect(verifyOpenWaSignature(new TextEncoder().encode('{"message":"مرحبا"}'), signature, TEST_SECRET)).toBe(false);
    expect(verifyOpenWaSignature(rawBytes, "sha256=invalid", TEST_SECRET)).toBe(false);
    expect(verifyOpenWaSignature(rawBytes, signature, "")).toBe(false);
  });
});

describe("OpenWA individual message normalization", () => {
  test("normalizes an explicitly individual inbound text message", () => {
    expect(parseOpenWaMessageEvent(payload())).toEqual({
      kind: "message",
      event: {
        sessionId: "session-opaque-01",
        chatId: "201001234567@c.us",
        messageId: "WA_IN_001",
        eventKey: expect.stringMatching(/^openwa:[a-f0-9]{64}$/u),
        direction: "inbound",
        contactJid: "201001234567@c.us",
        contactPhone: "201001234567",
        contactDisplay: "Maha",
        messageType: "text",
        bodyText: "مرحبا",
        providerMediaId: null,
        mediaMimeHint: null,
        caption: null,
        receivedAt: "2023-11-14T22:13:20.000Z",
      },
    });
  });

  test("normalizes a phone-originated message.sent echo against the chat peer", () => {
    const echo = payload({
      event: "message.sent",
      data: {
        id: "WA_OUT_001",
        from: "201599999999@c.us",
        to: "201001234567@c.us",
        chatId: "201001234567@c.us",
        body: "sent from the linked phone",
        type: "text",
        timestamp: 1_700_000_001,
        fromMe: true,
        isGroup: false,
        kind: "individual",
        contact: { pushName: "Business account" },
      },
    });

    expect(parseOpenWaMessageEvent(echo)).toMatchObject({
      kind: "message",
      event: {
        chatId: "201001234567@c.us",
        direction: "outbound",
        contactJid: "201001234567@c.us",
        contactPhone: "201001234567",
        contactDisplay: null,
        messageId: "WA_OUT_001",
        bodyText: "sent from the linked phone",
      },
    });
    expect(JSON.stringify(parseOpenWaMessageEvent(echo))).not.toContain("201599999999");
  });

  test("accepts an individual image only when OpenWA marks inline media omitted", () => {
    expect(parseOpenWaMessageEvent(payload({
      data: {
        id: "WA_IMAGE_001",
        from: "201001234567@c.us",
        to: "201599999999@c.us",
        chatId: "201001234567@c.us",
        body: "واجهة العقار",
        type: "image",
        timestamp: 1_700_000_002,
        fromMe: false,
        isGroup: false,
        kind: "individual",
        media: { mimetype: "image/jpeg", omitted: true, sizeBytes: 120_000 },
      },
    }))).toMatchObject({
      kind: "message",
      event: {
        messageId: "WA_IMAGE_001",
        direction: "inbound",
        messageType: "image",
        bodyText: null,
        providerMediaId: "WA_IMAGE_001",
        mediaMimeHint: "image/jpeg",
        caption: "واجهة العقار",
      },
    });
  });

  test("keeps an unresolved LID opaque and accepts only a separately resolved phone", () => {
    const lid = payload({
      data: {
        id: "WA_LID_001",
        from: "93847561029384@lid",
        to: "201599999999@c.us",
        chatId: "93847561029384@lid",
        body: "PRIVATE_OPENWA_SENTINEL",
        type: "text",
        timestamp: 1_700_000_003,
        fromMe: false,
        isGroup: false,
        kind: "individual",
        isLidSender: true,
        contact: { id: "93847561029384@lid", number: "201001234567", pushName: "LID contact" },
      },
    });

    expect(parseOpenWaMessageEvent(lid)).toMatchObject({
      kind: "message",
      event: {
        contactJid: "93847561029384@lid",
        contactPhone: null,
        contactDisplay: "LID contact",
      },
    });
    expect(parseOpenWaMessageEvent({
      ...lid,
      data: { ...lid.data, senderPhone: "201001234567" },
    })).toMatchObject({
      kind: "message",
      event: { contactJid: "93847561029384@lid", contactPhone: "201001234567" },
    });
  });

  test("does not treat senderPhone as a phone resolution for non-LID chats", () => {
    const event = parseOpenWaMessageEvent(payload({
      data: {
        ...payload().data,
        chatId: "opaque-contact@c.us",
        senderPhone: "201001234567",
      },
    }));

    expect(event).toMatchObject({
      kind: "message",
      event: { contactJid: "opaque-contact@c.us", contactPhone: null },
    });
  });

  test("derives a stable, session-scoped event key from the signed envelope", () => {
    const first = parseOpenWaMessageEvent(payload());
    const replay = parseOpenWaMessageEvent(payload());
    const anotherSession = parseOpenWaMessageEvent(payload({ sessionId: "session-opaque-02" }));
    const anotherDeliveryKey = parseOpenWaMessageEvent(payload({ idempotencyKey: "different-signed-key" }));

    expect(first.kind).toBe("message");
    expect(replay.kind).toBe("message");
    expect(anotherSession.kind).toBe("message");
    expect(anotherDeliveryKey.kind).toBe("message");
    if (first.kind !== "message" || replay.kind !== "message" || anotherSession.kind !== "message" || anotherDeliveryKey.kind !== "message") return;
    expect(replay.event.eventKey).toBe(first.event.eventKey);
    expect(anotherSession.event.eventKey).not.toBe(first.event.eventKey);
    expect(anotherDeliveryKey.event.eventKey).not.toBe(first.event.eventKey);
  });

  test.each([
    ["group JID", { chatId: "120363123456789@g.us" }],
    ["channel JID", { chatId: "123456789@newsletter" }],
    ["status JID", { chatId: "status@broadcast" }],
    ["broadcast JID", { chatId: "123456789@broadcast" }],
    ["missing kind", { kind: undefined }],
    ["unknown kind", { kind: "unknown" }],
    ["missing isGroup", { isGroup: undefined }],
    ["group flag", { isGroup: true }],
    ["status marker", { isStatusBroadcast: true }],
  ])("returns a field-free ignored result for a non-individual %s event", (_name, dataOverrides) => {
    expectIgnored(payload({
      data: {
        ...payload().data,
        ...dataOverrides,
        id: "PRIVATE_OPENWA_ID",
        body: "PRIVATE_OPENWA_SENTINEL",
      },
    }));
  });

  test.each([
    ["received event marked fromMe", "message.received", true],
    ["sent event not marked fromMe", "message.sent", false],
  ])("ignores inconsistent direction metadata: %s", (_name, event, fromMe) => {
    expectIgnored(payload({ event, data: { ...payload().data, fromMe } }));
  });

  test.each([
    ["unsupported media type", { type: "video" }],
    ["image without omission marker", { type: "image", media: { mimetype: "image/jpeg", data: "PRIVATE_OPENWA_SENTINEL" } }],
    ["oversized message body", { body: "x".repeat(4_097) }],
    ["oversized message identifier", { id: "x".repeat(321) }],
    ["oversized session identifier", { sessionId: "x".repeat(257) }],
  ])("ignores %s without returning input fields", (_name, overrides) => {
    const baseData = payload().data;
    const patch = "data" in overrides
      ? overrides
      : { data: { ...baseData, ...overrides } };
    expectIgnored(payload({
      ...patch,
      data: {
        ...(patch.data as Record<string, unknown>),
        id: "PRIVATE_OPENWA_ID",
        chatId: "PRIVATE_OPENWA_JID",
      },
    }));
  });

  test("ignores malformed envelopes and untrusted LID phone values", () => {
    expectIgnored(null);
    expectIgnored({ ...payload(), sessionId: "", data: null });
    const lid = payload({
      data: {
        ...payload().data,
        id: "WA_LID_INVALID_PHONE",
        from: "93847561029384@lid",
        chatId: "93847561029384@lid",
        isLidSender: true,
        senderPhone: "+201001234567",
      },
    });
    expect(parseOpenWaMessageEvent(lid)).toMatchObject({
      kind: "message",
      event: { contactPhone: null },
    });
  });
});
