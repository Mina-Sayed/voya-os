import { createHmac } from "node:crypto";
import { NextRequest } from "next/server";
import { afterEach, describe, expect, test, vi } from "vitest";

const runtime = vi.hoisted(() => ({ rpc: vi.fn(), clientCreated: vi.fn() }));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServiceRoleSupabaseClient: vi.fn(() => {
    runtime.clientCreated();
    return { rpc: runtime.rpc };
  }),
}));

import { POST } from "./route";

const TEST_SECRET = "synthetic-openwa-route-test-secret";
const sessionId = "session-opaque-01";
const signedKey = "msg_session-opaque-01_WA_IN_001";

function messageEnvelope(overrides: Record<string, unknown> = {}) {
  return {
    event: "message.received",
    timestamp: "2026-09-25T10:00:00.000Z",
    sessionId,
    idempotencyKey: signedKey,
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

function signedRequest(body: string, headerOverrides: Record<string, string | null> = {}) {
  const signature = createHmac("sha256", TEST_SECRET).update(new TextEncoder().encode(body)).digest("hex");
  const headers = new Headers({
    "x-openwa-signature": `sha256=${signature}`,
    "x-openwa-idempotency-key": signedKey,
  });
  for (const [name, value] of Object.entries(headerOverrides)) {
    if (value === null) headers.delete(name);
    else headers.set(name, value);
  }
  return new NextRequest("https://voya.test/api/webhooks/whatsapp/openwa", {
    method: "POST",
    headers,
    body,
  });
}

function streamedRequest(body: string) {
  const signature = createHmac("sha256", TEST_SECRET).update(new TextEncoder().encode(body)).digest("hex");
  const chunks = [
    new TextEncoder().encode("x".repeat(128 * 1024)),
    new TextEncoder().encode("x".repeat(128 * 1024 + 1)),
  ];
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });
  return {
    headers: new Headers({
      "x-openwa-signature": `sha256=${signature}`,
      "x-openwa-idempotency-key": signedKey,
    }),
    body: stream,
  } as unknown as NextRequest;
}

function mockOpenWaResolution(provider: unknown = "openwa", ingestError: unknown = null) {
  runtime.rpc.mockImplementation(async (name: string) => {
    if (name === "resolve_whatsapp_webhook_provider_v1") return { data: provider, error: null };
    if (name === "ingest_whatsapp_openwa_event_v1") return { data: "message-id", error: ingestError };
    return { data: null, error: { code: "XX000" } };
  });
}

afterEach(() => {
  vi.clearAllMocks();
  delete process.env.OPENWA_WEBHOOK_SECRET;
  delete process.env.SUPABASE_SERVICE_ROLE_KEY;
});

describe("OpenWA webhook route", () => {
  test("rejects invalid signatures before constructing the service-role client", async () => {
    process.env.OPENWA_WEBHOOK_SECRET = TEST_SECRET;
    const response = await POST(signedRequest("{}", { "x-openwa-signature": "sha256=invalid" }));

    expect(response.status).toBe(401);
    expect(runtime.clientCreated).not.toHaveBeenCalled();
    expect(runtime.rpc).not.toHaveBeenCalled();
  });

  test("returns unavailable when the signing secret is missing", async () => {
    const response = await POST(signedRequest(JSON.stringify(messageEnvelope())));

    expect(response.status).toBe(503);
    expect(runtime.clientCreated).not.toHaveBeenCalled();
    expect(runtime.rpc).not.toHaveBeenCalled();
  });

  test("verifies the signature over the exact raw body bytes before parsing JSON", async () => {
    process.env.OPENWA_WEBHOOK_SECRET = TEST_SECRET;
    process.env.SUPABASE_SERVICE_ROLE_KEY = "synthetic-service-role-test-key";
    mockOpenWaResolution();
    const original = JSON.stringify(messageEnvelope());
    const altered = `${original} `;

    const response = await POST(signedRequest(altered, {
      "x-openwa-signature": `sha256=${createHmac("sha256", TEST_SECRET).update(new TextEncoder().encode(original)).digest("hex")}`,
    }));

    expect(response.status).toBe(401);
    expect(runtime.rpc).not.toHaveBeenCalled();
  });

  test("returns 400 for malformed JSON with a valid signature", async () => {
    process.env.OPENWA_WEBHOOK_SECRET = TEST_SECRET;
    const response = await POST(signedRequest("{not-json"));

    expect(response.status).toBe(400);
    expect(runtime.rpc).not.toHaveBeenCalled();
  });

  test.each([
    ["declared", () => new NextRequest("https://voya.test/api/webhooks/whatsapp/openwa", {
      method: "POST",
      headers: {
        "content-length": String(256 * 1024 + 1),
        "x-openwa-signature": "sha256=ignored",
        "x-openwa-idempotency-key": signedKey,
      },
      body: "{}",
    })],
    ["streamed", () => streamedRequest("not-the-stream-body")],
  ])("returns 413 for an oversized %s request body", async (_kind, buildRequest) => {
    process.env.OPENWA_WEBHOOK_SECRET = TEST_SECRET;
    const response = await POST(buildRequest());

    expect(response.status).toBe(413);
    expect(runtime.rpc).not.toHaveBeenCalled();
  });

  test.each([
    ["missing", { "x-openwa-idempotency-key": null }],
    ["mismatched", { "x-openwa-idempotency-key": "different-header-key" }],
  ])("rejects a %s idempotency header without making Supabase calls", async (_kind, headers) => {
    process.env.OPENWA_WEBHOOK_SECRET = TEST_SECRET;
    const response = await POST(signedRequest(JSON.stringify(messageEnvelope()), headers));

    expect(response.status).toBe(401);
    expect(runtime.clientCreated).not.toHaveBeenCalled();
    expect(runtime.rpc).not.toHaveBeenCalled();
  });

  test("acknowledges a signed group event without creating a Supabase client", async () => {
    process.env.OPENWA_WEBHOOK_SECRET = TEST_SECRET;
    const envelope = messageEnvelope({
      data: {
        ...messageEnvelope().data,
        id: "PRIVATE_OPENWA_ID",
        chatId: "120363123456789@g.us",
        body: "PRIVATE_OPENWA_SENTINEL",
        kind: "group",
        isGroup: true,
      },
    });
    const response = await POST(signedRequest(JSON.stringify(envelope)));

    expect(response.status).toBe(202);
    await expect(response.json()).resolves.toEqual({ accepted: true, ignored: true });
    expect(runtime.clientCreated).not.toHaveBeenCalled();
    expect(runtime.rpc).not.toHaveBeenCalled();
  });

  test("resolves only the OpenWA provider and ingests an inbound message through the service role", async () => {
    process.env.OPENWA_WEBHOOK_SECRET = TEST_SECRET;
    process.env.SUPABASE_SERVICE_ROLE_KEY = "synthetic-service-role-test-key";
    mockOpenWaResolution();
    const response = await POST(signedRequest(JSON.stringify(messageEnvelope())));

    expect(response.status).toBe(202);
    await expect(response.json()).resolves.toEqual({ accepted: true, events: 1 });
    expect(runtime.rpc).toHaveBeenCalledWith("resolve_whatsapp_webhook_provider_v1", {
      p_external_channel_id: sessionId,
      p_preferred_provider: "openwa",
    });
    expect(runtime.rpc).toHaveBeenCalledWith("ingest_whatsapp_openwa_event_v1", {
      p_external_channel_id: sessionId,
      p_chat_id: "201001234567@c.us",
      p_event_key: expect.stringMatching(/^openwa:[a-f0-9]{64}$/u),
      p_provider_message_id: "WA_IN_001",
      p_contact_jid: "201001234567@c.us",
      p_contact_phone: "201001234567",
      p_contact_display: "Maha",
      p_direction: "inbound",
      p_message_type: "text",
      p_body_text: "مرحبا",
      p_provider_media_id: null,
      p_media_mime_hint: null,
      p_caption: null,
      p_received_at: "2023-11-14T22:13:20.000Z",
    });
    expect(JSON.stringify(runtime.rpc.mock.calls)).not.toContain("synthetic-service-role-test-key");
  });

  test("records an outbound echo without changing its peer to data.from", async () => {
    process.env.OPENWA_WEBHOOK_SECRET = TEST_SECRET;
    process.env.SUPABASE_SERVICE_ROLE_KEY = "synthetic-service-role-test-key";
    mockOpenWaResolution();
    const envelope = messageEnvelope({
      event: "message.sent",
      data: {
        ...messageEnvelope().data,
        id: "WA_OUT_001",
        from: "201599999999@c.us",
        to: "201001234567@c.us",
        chatId: "201001234567@c.us",
        body: "sent from phone",
        fromMe: true,
      },
    });
    const response = await POST(signedRequest(JSON.stringify(envelope)));

    expect(response.status).toBe(202);
    expect(runtime.rpc).toHaveBeenCalledWith("ingest_whatsapp_openwa_event_v1", expect.objectContaining({
      p_provider_message_id: "WA_OUT_001",
      p_chat_id: "201001234567@c.us",
      p_contact_jid: "201001234567@c.us",
      p_contact_phone: "201001234567",
      p_direction: "outbound",
    }));
    expect(JSON.stringify(runtime.rpc.mock.calls)).not.toContain("201599999999");
  });

  test("rejects an unknown session and rejects a Meta resolver fallback", async () => {
    process.env.OPENWA_WEBHOOK_SECRET = TEST_SECRET;
    process.env.SUPABASE_SERVICE_ROLE_KEY = "synthetic-service-role-test-key";
    const body = JSON.stringify(messageEnvelope());

    mockOpenWaResolution(null);
    const unknown = await POST(signedRequest(body));
    expect(unknown.status).toBe(503);
    expect(runtime.rpc).toHaveBeenCalledTimes(1);
    expect(runtime.rpc).not.toHaveBeenCalledWith("ingest_whatsapp_openwa_event_v1", expect.anything());

    vi.clearAllMocks();
    mockOpenWaResolution("meta_cloud");
    const fallback = await POST(signedRequest(body));
    expect(fallback.status).toBe(503);
    expect(runtime.rpc).toHaveBeenCalledWith("resolve_whatsapp_webhook_provider_v1", {
      p_external_channel_id: sessionId,
      p_preferred_provider: "openwa",
    });
    expect(runtime.rpc).not.toHaveBeenCalledWith("ingest_whatsapp_openwa_event_v1", expect.anything());
  });

  test("uses the same dedupe key on a duplicate delivery", async () => {
    process.env.OPENWA_WEBHOOK_SECRET = TEST_SECRET;
    process.env.SUPABASE_SERVICE_ROLE_KEY = "synthetic-service-role-test-key";
    mockOpenWaResolution();
    const body = JSON.stringify(messageEnvelope());

    const first = await POST(signedRequest(body));
    const duplicate = await POST(signedRequest(body));

    expect(first.status).toBe(202);
    expect(duplicate.status).toBe(202);
    const eventKeys = runtime.rpc.mock.calls
      .filter(([name]) => name === "ingest_whatsapp_openwa_event_v1")
      .map(([, args]) => (args as { p_event_key: string }).p_event_key);
    expect(eventKeys).toHaveLength(2);
    expect(eventKeys[0]).toMatch(/^openwa:[a-f0-9]{64}$/u);
    expect(eventKeys[1]).toBe(eventKeys[0]);
  });

  test("returns 503 when durable ingestion fails so OpenWA can retry", async () => {
    process.env.OPENWA_WEBHOOK_SECRET = TEST_SECRET;
    process.env.SUPABASE_SERVICE_ROLE_KEY = "synthetic-service-role-test-key";
    mockOpenWaResolution("openwa", { code: "XX000" });
    const response = await POST(signedRequest(JSON.stringify(messageEnvelope())));

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toEqual({ error: "ingestion_failed" });
  });
});
