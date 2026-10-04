import { describe, expect, it, vi } from "vitest";
import {
  dispatchOutboxEvent,
  getOutboxRetryDelaySeconds,
  type OutboxDispatchDependencies,
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

const dependencies = (overrides: Partial<OutboxDispatchDependencies> = {}): OutboxDispatchDependencies => ({
  emailEnabled: false,
  whatsappEnabled: true,
  openWaEnabled: false,
  applicationUrl: "https://app.example.test",
  sendEmail: vi.fn().mockResolvedValue({ kind: "delivered" as const }),
  renewWhatsAppLease: vi.fn().mockResolvedValue(true),
  sendWhatsApp: vi.fn().mockResolvedValue({ kind: "delivered" as const, providerMessageId: "provider-message-1" }),
  ...overrides,
});

describe("outbox dispatch contract", () => {
  it("uses the V1 retry schedule and stops after the sixth delivery attempt", () => {
    expect([1, 2, 3, 4, 5].map(getOutboxRetryDelaySeconds)).toEqual([60, 300, 900, 3600, 21600]);
    expect(getOutboxRetryDelaySeconds(6)).toBeNull();
  });

  it("builds an idempotent Resend invitation request without accepting an unsupported event", async () => {
    const sendEmail = vi.fn().mockResolvedValue({ kind: "delivered" as const });

    const result = await dispatchOutboxEvent(event(), dependencies({ emailEnabled: true, sendEmail }));

    expect(result).toEqual({ outcome: "completed" });
    expect(sendEmail).toHaveBeenCalledWith(expect.objectContaining({
      to: "member@example.test",
      idempotencyKey: "event-1",
      html: expect.stringContaining("https://app.example.test/invite?token=one-time-token"),
    }));
  });

  it("marks a disabled channel for review instead of silently completing the event", async () => {
    const result = await dispatchOutboxEvent(event(), dependencies({ emailEnabled: false, whatsappEnabled: false }));

    expect(result).toEqual({ outcome: "needs_review", errorCode: "email_delivery_disabled" });
  });

  it("routes a Meta destination with its provider channel and recipient unchanged", async () => {
    const sendWhatsApp = vi.fn().mockResolvedValue({ kind: "delivered" as const, providerMessageId: "wamid-meta-1" });
    const renewWhatsAppLease = vi.fn().mockResolvedValue(true);
    const result = await dispatchOutboxEvent(event({
      event_type: "whatsapp.message.send_requested",
      payload: {
        provider: "meta_cloud",
        providerChannelId: "meta-phone-1",
        recipientPhone: "+201001234567",
        body: "مرحبا",
      },
    }), dependencies({ sendWhatsApp, renewWhatsAppLease }));

    expect(result).toEqual({ outcome: "completed", providerMessageId: "wamid-meta-1" });
    expect(sendWhatsApp).toHaveBeenCalledWith({
      provider: "meta_cloud",
      phoneNumberId: "meta-phone-1",
      to: "+201001234567",
      body: "مرحبا",
      idempotencyKey: "event-1",
    });
    expect(renewWhatsAppLease.mock.invocationCallOrder[0]).toBeLessThan(sendWhatsApp.mock.invocationCallOrder[0]);
  });

  it("routes an enabled OpenWA destination with the session and individual JID", async () => {
    const sendWhatsApp = vi.fn().mockResolvedValue({ kind: "delivered" as const, providerMessageId: "openwa-message-1" });
    const result = await dispatchOutboxEvent(event({
      event_type: "whatsapp.message.send_requested",
      payload: {
        provider: "openwa",
        providerChannelId: "openwa-session-a",
        chatId: "201001234567@c.us",
        body: "مرحبا",
      },
    }), dependencies({ openWaEnabled: true, sendWhatsApp }));

    expect(result).toEqual({ outcome: "completed", providerMessageId: "openwa-message-1" });
    expect(sendWhatsApp).toHaveBeenCalledWith({
      provider: "openwa",
      sessionId: "openwa-session-a",
      chatId: "201001234567@c.us",
      body: "مرحبا",
      idempotencyKey: "event-1",
    });
  });

  it("routes a Meta sandbox channel through the Meta delivery contract", async () => {
    const sendWhatsApp = vi.fn().mockResolvedValue({ kind: "delivered" as const, providerMessageId: "wamid-sandbox-1" });
    await dispatchOutboxEvent(event({
      event_type: "whatsapp.message.send_requested",
      payload: {
        provider: "meta_cloud_sandbox",
        providerChannelId: "sandbox-phone-1",
        recipientPhone: "+201001234567",
        body: "مرحبا",
      },
    }), dependencies({ sendWhatsApp }));

    expect(sendWhatsApp).toHaveBeenCalledWith(expect.objectContaining({
      provider: "meta_cloud_sandbox",
      phoneNumberId: "sandbox-phone-1",
    }));
  });

  it("rejects unknown providers and OpenWA group JIDs before renewing or sending", async () => {
    const sendWhatsApp = vi.fn();
    const renewWhatsAppLease = vi.fn().mockResolvedValue(true);
    const base = {
      event_type: "whatsapp.message.send_requested",
      payload: { providerChannelId: "session-a", body: "مرحبا" },
    };

    await expect(dispatchOutboxEvent(event({ ...base, payload: { ...base.payload, provider: "unknown" } }), dependencies({ sendWhatsApp, renewWhatsAppLease })))
      .resolves.toEqual({ outcome: "needs_review", errorCode: "whatsapp_provider_unknown" });
    await expect(dispatchOutboxEvent(event({
      ...base,
      payload: { ...base.payload, provider: "openwa", chatId: "120363000000000000@g.us" },
    }), dependencies({ openWaEnabled: true, sendWhatsApp, renewWhatsAppLease })))
      .resolves.toEqual({ outcome: "needs_review", errorCode: "whatsapp_destination_invalid" });

    expect(renewWhatsAppLease).not.toHaveBeenCalled();
    expect(sendWhatsApp).not.toHaveBeenCalled();
  });

  it("gates OpenWA behind its explicit flag as well as the global WhatsApp flag", async () => {
    const sendWhatsApp = vi.fn();
    const payload = {
      provider: "openwa",
      providerChannelId: "openwa-session-a",
      chatId: "201001234567@c.us",
      body: "مرحبا",
    };

    await expect(dispatchOutboxEvent(event({ event_type: "whatsapp.message.send_requested", payload }), dependencies({ sendWhatsApp })))
      .resolves.toEqual({ outcome: "needs_review", errorCode: "openwa_delivery_disabled" });
    await expect(dispatchOutboxEvent(event({ event_type: "whatsapp.message.send_requested", payload }), dependencies({
      whatsappEnabled: false,
      openWaEnabled: true,
      sendWhatsApp,
    }))).resolves.toEqual({ outcome: "needs_review", errorCode: "whatsapp_delivery_disabled" });

    expect(sendWhatsApp).not.toHaveBeenCalled();
  });

  it("does not invoke either provider when the delivery lease cannot be renewed", async () => {
    const sendWhatsApp = vi.fn();
    const payloads = [
      {
        provider: "meta_cloud",
        providerChannelId: "meta-phone-1",
        recipientPhone: "+201001234567",
        body: "مرحبا",
      },
      {
        provider: "openwa",
        providerChannelId: "openwa-session-a",
        chatId: "201001234567@c.us",
        body: "مرحبا",
      },
    ];

    for (const payload of payloads) {
      await expect(dispatchOutboxEvent(event({ event_type: "whatsapp.message.send_requested", payload }), dependencies({
        openWaEnabled: true,
        renewWhatsAppLease: vi.fn().mockResolvedValue(false),
        sendWhatsApp,
      }))).resolves.toEqual({ outcome: "needs_review", errorCode: "outbox_lease_lost" });
    }

    expect(sendWhatsApp).not.toHaveBeenCalled();
  });

  it("maps ambiguous results and missing provider IDs to review without blind retry", async () => {
    const sendWhatsApp = vi.fn()
      .mockResolvedValueOnce({ kind: "ambiguous" as const, errorCode: "openwa_delivery_unknown" })
      .mockResolvedValueOnce({ kind: "delivered" as const });
    const input = event({
      event_type: "whatsapp.message.send_requested",
      payload: {
        provider: "openwa",
        providerChannelId: "openwa-session-a",
        chatId: "201001234567@c.us",
        body: "مرحبا",
      },
    });

    await expect(dispatchOutboxEvent(input, dependencies({ openWaEnabled: true, sendWhatsApp })))
      .resolves.toEqual({ outcome: "needs_review", errorCode: "openwa_delivery_unknown" });
    await expect(dispatchOutboxEvent(input, dependencies({ openWaEnabled: true, sendWhatsApp })))
      .resolves.toEqual({ outcome: "needs_review", errorCode: "whatsapp_provider_id_missing" });
    expect(sendWhatsApp).toHaveBeenCalledTimes(2);
  });

  it("maps a delivered provider result with an ID to completed and preserves Meta ambiguity handling", async () => {
    const result = await dispatchOutboxEvent(
      event({ event_type: "whatsapp.message.send_requested", payload: {
        provider: "meta_cloud",
        providerChannelId: "meta-phone-1",
        recipientPhone: "+201000000000",
        body: "مرحبا",
      } }),
      dependencies({ sendWhatsApp: vi.fn().mockResolvedValue({ kind: "ambiguous", errorCode: "provider_timeout" }) }),
    );

    expect(result).toEqual({ outcome: "needs_review", errorCode: "provider_timeout" });
  });
});
