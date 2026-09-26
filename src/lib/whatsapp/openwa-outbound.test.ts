import { describe, expect, it, vi } from "vitest";
import { createOpenWaOutboundAdapter } from "./openwa-outbound";

const request = {
  provider: "openwa" as const,
  sessionId: "session/primary",
  chatId: "+201001234567",
  body: "مرحبا",
  idempotencyKey: "event-1",
};

describe("OpenWA outbound adapter", () => {
  it("sends text to the configured session and converts a phone to a c.us JID", async () => {
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ messageId: "openwa-message-1", timestamp: "2026-09-25T08:00:00.000Z" }), { status: 201 }));
    const adapter = createOpenWaOutboundAdapter({
      baseUrl: "https://openwa.example.test",
      apiKey: "server-only-key",
      fetchImpl,
    });

    await expect(adapter.send(request)).resolves.toEqual({
      kind: "delivered",
      providerMessageId: "openwa-message-1",
    });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(fetchImpl).toHaveBeenCalledWith(
      "https://openwa.example.test/api/sessions/session%2Fprimary/messages/send-text",
      expect.objectContaining({
        method: "POST",
        redirect: "error",
        headers: { "X-API-Key": "server-only-key", "content-type": "application/json" },
        body: JSON.stringify({ chatId: "201001234567@c.us", text: "مرحبا" }),
      }),
    );
  });

  it("passes an individual LID JID through unchanged", async () => {
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ messageId: "lid-message-1" }), { status: 200 }));
    const adapter = createOpenWaOutboundAdapter({
      baseUrl: "https://openwa.example.test",
      apiKey: "server-only-key",
      fetchImpl,
    });

    await adapter.send({ ...request, chatId: "93847561029384@lid" });

    expect(fetchImpl).toHaveBeenCalledWith(
      expect.any(String),
      expect.objectContaining({ body: JSON.stringify({ chatId: "93847561029384@lid", text: "مرحبا" }) }),
    );
  });

  it.each([
    ["group JID", "120363000000000000@g.us"],
    ["newsletter JID", "123456789@newsletter"],
    ["status broadcast", "status@broadcast"],
    ["unknown chat ID", "customer-123"],
  ])("rejects %s before making a request", async (_label, chatId) => {
    const fetchImpl = vi.fn(async () => new Response("unexpected", { status: 200 }));
    const adapter = createOpenWaOutboundAdapter({
      baseUrl: "https://openwa.example.test",
      apiKey: "server-only-key",
      fetchImpl,
    });

    await expect(adapter.send({ ...request, chatId })).resolves.toMatchObject({ kind: "permanent" });
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("rejects cleartext transport to non-loopback hosts and permits literal loopback development URLs", () => {
    expect(() => createOpenWaOutboundAdapter({ baseUrl: "http://openwa.example.test", apiKey: "server-only-key" }))
      .toThrow("HTTPS is required for OpenWA outbound outside loopback.");
    expect(() => createOpenWaOutboundAdapter({ baseUrl: "http://localhost:55322", apiKey: "server-only-key" }))
      .toThrow("HTTPS is required for OpenWA outbound outside loopback.");
    expect(() => createOpenWaOutboundAdapter({ baseUrl: "http://127.0.0.1:55322", apiKey: "server-only-key" })).not.toThrow();
    expect(() => createOpenWaOutboundAdapter({ baseUrl: "http://[::1]:55322", apiKey: "server-only-key" })).not.toThrow();
  });

  it.each([
    [409, { kind: "retryable", errorCode: "openwa_session_not_ready" }],
    [429, { kind: "retryable", errorCode: "openwa_rate_limited" }],
    [401, { kind: "permanent", errorCode: "openwa_auth_denied" }],
    [403, { kind: "permanent", errorCode: "openwa_auth_denied" }],
  ] as const)("maps HTTP %i without retrying inside the adapter", async (status, result) => {
    const fetchImpl = vi.fn(async () => new Response("provider response", { status }));
    const adapter = createOpenWaOutboundAdapter({
      baseUrl: "https://openwa.example.test",
      apiKey: "server-only-key",
      fetchImpl,
    });

    await expect(adapter.send(request)).resolves.toEqual(result);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("marks a malformed success response ambiguous because delivery may have occurred", async () => {
    const fetchImpl = vi.fn(async () => new Response("not-json", { status: 200 }));
    const adapter = createOpenWaOutboundAdapter({
      baseUrl: "https://openwa.example.test",
      apiKey: "server-only-key",
      fetchImpl,
    });

    await expect(adapter.send(request)).resolves.toEqual({ kind: "ambiguous", errorCode: "openwa_delivery_unknown" });
  });

  it("does not trim a padded provider message ID into a different reconciliation key", async () => {
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ messageId: " openwa-message-1 " }), { status: 201 }));
    const adapter = createOpenWaOutboundAdapter({
      baseUrl: "https://openwa.example.test",
      apiKey: "server-only-key",
      fetchImpl,
    });

    await expect(adapter.send(request)).resolves.toEqual({ kind: "ambiguous", errorCode: "openwa_delivery_unknown" });
  });

  it("keeps an HTTP 500 response ambiguous because the send may have reached WhatsApp", async () => {
    const fetchImpl = vi.fn(async () => new Response("internal server error", { status: 500 }));
    const adapter = createOpenWaOutboundAdapter({
      baseUrl: "https://openwa.example.test",
      apiKey: "server-only-key",
      fetchImpl,
    });

    await expect(adapter.send(request)).resolves.toEqual({ kind: "ambiguous", errorCode: "openwa_delivery_unknown" });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("retries only a synchronous pre-request failure and treats post-dispatch failure or timeout as ambiguous", async () => {
    const beforeRequest = vi.fn(() => {
      throw new TypeError("request setup failed");
    });
    const afterDispatch = vi.fn().mockRejectedValue(new TypeError("connection closed"));
    const timeout = vi.fn().mockRejectedValue(Object.assign(new Error("timed out"), { name: "AbortError" }));
    const makeAdapter = (fetchImpl: typeof fetch) => createOpenWaOutboundAdapter({
      baseUrl: "https://openwa.example.test",
      apiKey: "server-only-key",
      fetchImpl,
    });

    await expect(makeAdapter(beforeRequest).send(request)).resolves.toEqual({
      kind: "retryable",
      errorCode: "openwa_request_setup_failed",
    });
    await expect(makeAdapter(afterDispatch).send(request)).resolves.toEqual({
      kind: "ambiguous",
      errorCode: "openwa_delivery_unknown",
    });
    await expect(makeAdapter(timeout).send(request)).resolves.toEqual({
      kind: "ambiguous",
      errorCode: "openwa_delivery_unknown",
    });
  });
});
