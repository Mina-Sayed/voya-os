import { describe, expect, it, vi } from "vitest";
import { createResendEmailAdapter } from "./resend";

const request = {
  to: "member@example.test",
  subject: "دعوة",
  text: "افتح الدعوة",
  html: "<p>افتح الدعوة</p>",
  idempotencyKey: "event-1",
};

describe("Resend email adapter", () => {
  it("sends only the bounded transactional email fields with both auth and idempotency headers", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response(JSON.stringify({ id: "resend-1" }), { status: 200 }));
    const adapter = createResendEmailAdapter({
      apiKey: "re_test_secret",
      from: "Voya OS <noreply@example.test>",
      fetchImpl,
    });

    await expect(adapter.send(request)).resolves.toEqual({ kind: "delivered", providerMessageId: "resend-1" });
    expect(fetchImpl).toHaveBeenCalledWith("https://api.resend.com/emails", expect.objectContaining({
      method: "POST",
      headers: {
        authorization: "Bearer re_test_secret",
        "content-type": "application/json",
        "idempotency-key": "event-1",
      },
      body: JSON.stringify({
        from: "Voya OS <noreply@example.test>",
        to: ["member@example.test"],
        subject: "دعوة",
        text: "افتح الدعوة",
        html: "<p>افتح الدعوة</p>",
      }),
    }));
  });

  it("maps provider rate limits to retry and network timeouts to needs_review", async () => {
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(new Response("busy", { status: 429 }))
      .mockRejectedValueOnce(Object.assign(new Error("timeout"), { name: "AbortError" }));
    const adapter = createResendEmailAdapter({ apiKey: "re_test_secret", from: "noreply@example.test", fetchImpl, timeoutMs: 1000 });

    await expect(adapter.send(request)).resolves.toEqual({ kind: "retryable", errorCode: "email_rate_limited" });
    await expect(adapter.send(request)).resolves.toEqual({ kind: "ambiguous", errorCode: "email_provider_timeout" });
  });

  it("fails closed when the provider key or sender is missing", () => {
    expect(() => createResendEmailAdapter({ apiKey: "", from: "noreply@example.test" })).toThrow("Resend");
    expect(() => createResendEmailAdapter({ apiKey: "re_test_secret", from: "" })).toThrow("Resend");
  });
});
