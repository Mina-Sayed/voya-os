import { describe, expect, it, vi } from "vitest";
import {
  dispatchOutboxEvent,
  getOutboxRetryDelaySeconds,
  type OutboxEvent,
} from "./dispatch-contract";

const event = (overrides: Partial<OutboxEvent> = {}): OutboxEvent => ({
  id: "event-1",
  event_type: "organization.invitation.send_requested",
  schema_version: 1,
  attempts: 1,
  payload: {
    email: "member@example.test",
    role: "operator",
    token: "one-time-token",
  },
  ...overrides,
});

describe("outbox dispatch contract", () => {
  it("uses the V1 retry schedule and stops after the sixth delivery attempt", () => {
    expect([1, 2, 3, 4, 5].map(getOutboxRetryDelaySeconds)).toEqual([60, 300, 900, 3600, 21600]);
    expect(getOutboxRetryDelaySeconds(6)).toBeNull();
  });

  it("builds an idempotent Resend invitation request without accepting an unsupported event", async () => {
    const sendEmail = vi.fn().mockResolvedValue({ kind: "delivered" as const });

    const result = await dispatchOutboxEvent(event(), {
      emailEnabled: true,
      whatsappEnabled: false,
      applicationUrl: "https://app.example.test",
      sendEmail,
      sendWhatsApp: vi.fn(),
    });

    expect(result).toEqual({ outcome: "completed" });
    expect(sendEmail).toHaveBeenCalledWith(expect.objectContaining({
      to: "member@example.test",
      idempotencyKey: "event-1",
      html: expect.stringContaining("https://app.example.test/invite?token=one-time-token"),
    }));
  });

  it("marks a disabled channel for review instead of silently completing the event", async () => {
    const result = await dispatchOutboxEvent(event(), {
      emailEnabled: false,
      whatsappEnabled: false,
      applicationUrl: "https://app.example.test",
      sendEmail: vi.fn(),
      sendWhatsApp: vi.fn(),
    });

    expect(result).toEqual({ outcome: "needs_review", errorCode: "email_delivery_disabled" });
  });

  it("maps an ambiguous provider result to needs_review and never retries blindly", async () => {
    const result = await dispatchOutboxEvent(
      event({ event_type: "whatsapp.message.send_requested", payload: { to: "+201000000000", body: "مرحبا", phoneNumberId: "phone-1" } }),
      {
        emailEnabled: false,
        whatsappEnabled: true,
        applicationUrl: "https://app.example.test",
        sendEmail: vi.fn(),
        sendWhatsApp: vi.fn().mockResolvedValue({ kind: "ambiguous", errorCode: "provider_timeout" }),
      },
    );

    expect(result).toEqual({ outcome: "needs_review", errorCode: "provider_timeout" });
  });
});
