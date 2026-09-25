import { describe, expect, test, vi } from "vitest";
import * as whatsappAiWorker from "./whatsapp-ai-worker";
import {
  buildWhatsappAiGenerationRequest,
  buildWhatsappMediaStoragePath,
  projectWhatsappAiResponse,
  shouldMarkWhatsappMediaFailed,
  shouldSendWhatsappReply,
  toWhatsappHistory,
} from "./whatsapp-ai-worker";
import type { WhatsappConversationState, WhatsappAiResponse } from "../../domain/ai/whatsapp-agent-contract";

const state: WhatsappConversationState = {
  language: "ar",
  owner: null,
  property: {
    address: null,
    city: "Nasr City",
    district: "Abbas El Akkad",
    unitLabel: null,
    bedrooms: 3,
    maxGuests: 5,
    bathrooms: 2,
    areaSqm: null,
    floor: null,
    operationalNotes: null,
    furnished: true,
    rentDaily: null,
    rentWeekly: null,
    rentMonthly: true,
    dailyPrice: null,
    weeklyPrice: null,
    monthlyPrice: 35000,
    currency: "EGP",
    amenities: [],
    minimumStayNights: null,
    marketingDescription: null,
    availabilityText: null,
  },
  lead: null,
  missingFields: [],
  confidence: "high",
  imageMessageIds: [],
};

const ownerResponse: WhatsappAiResponse = {
  conversationType: "owner_onboarding",
  facts: {
    language: "ar",
    owner: { displayName: null, phone: "+201000000000", whatsapp: "+201000000000", email: null, preferredContactMethod: "whatsapp", notes: null },
    property: state.property,
    lead: null,
  },
  missingFields: ["property.photos"],
  reply: "ابعت صور الشقة من فضلك.",
  recommendedAction: "continue",
  confidence: "high",
};

type MediaSelectionInput = Readonly<{
  provider: string;
  providerChannelId: string | null;
  chatId: string | null;
  messageType: string;
  mediaStatus: string;
  providerMediaId: string | null;
  mimeTypeHint: string | null;
}>;
type MediaAdapterSet = Readonly<{
  openWa: Readonly<{ download(request: Readonly<Record<string, unknown>>): Promise<unknown> }> | null;
  meta: Readonly<{ download(request: Readonly<Record<string, unknown>>): Promise<unknown> }> | null;
}>;
type MediaSelector = (input: MediaSelectionInput, adapters: MediaAdapterSet) => Promise<unknown>;

function getMediaSelector(): MediaSelector | undefined {
  const selector = (whatsappAiWorker as unknown as Record<string, unknown>).downloadWhatsappMediaForProvider;
  expect(selector).toBeTypeOf("function");
  return typeof selector === "function" ? selector as MediaSelector : undefined;
}

describe("WhatsApp AI worker helpers", () => {
  test("uses the OpenWA session, chat JID, and message ID for image retrieval", async () => {
    const download = getMediaSelector();
    if (!download) return;
    const openWaMedia = { download: vi.fn().mockResolvedValue({ mimeType: "image/jpeg", sizeBytes: 3, bytes: new Uint8Array([1, 2, 3]) }) };
    const metaMedia = { download: vi.fn() };

    await download({
      provider: "openwa",
      providerChannelId: "openwa-session-1",
      chatId: "201001234567@c.us",
      messageType: "image",
      mediaStatus: "pending",
      providerMediaId: "OPENWA_MESSAGE_ID_1",
      mimeTypeHint: "image/jpeg",
    }, { openWa: openWaMedia, meta: metaMedia });

    expect(openWaMedia.download).toHaveBeenCalledWith({
      sessionId: "openwa-session-1",
      chatId: "201001234567@c.us",
      messageId: "OPENWA_MESSAGE_ID_1",
      mimeTypeHint: "image/jpeg",
    });
    expect(metaMedia.download).not.toHaveBeenCalled();
  });

  test("rejects group chat IDs before calling either media adapter", async () => {
    const download = getMediaSelector();
    if (!download) return;
    const openWaMedia = { download: vi.fn().mockResolvedValue({ mimeType: "image/jpeg", sizeBytes: 3, bytes: new Uint8Array([1, 2, 3]) }) };
    const metaMedia = { download: vi.fn() };

    await expect(download({
      provider: "openwa",
      providerChannelId: "openwa-session-1",
      chatId: "120363123456789@g.us",
      messageType: "image",
      mediaStatus: "pending",
      providerMediaId: "OPENWA_GROUP_IMAGE_ID",
      mimeTypeHint: "image/jpeg",
    }, { openWa: openWaMedia, meta: metaMedia })).rejects.toMatchObject({ message: "whatsapp_media_invalid_request" });
    expect(openWaMedia.download).not.toHaveBeenCalled();
    expect(metaMedia.download).not.toHaveBeenCalled();
  });

  test("keeps Meta image retrieval on its provider media ID", async () => {
    const download = getMediaSelector();
    if (!download) return;
    const openWaMedia = { download: vi.fn() };
    const metaMedia = { download: vi.fn().mockResolvedValue({ mimeType: "image/jpeg", sizeBytes: 3, bytes: new Uint8Array([1, 2, 3]) }) };

    await download({
      provider: "meta_cloud_sandbox",
      providerChannelId: "meta-phone-number-id",
      chatId: "meta-conversation-key",
      messageType: "image",
      mediaStatus: "pending",
      providerMediaId: "META_MEDIA_ID_1",
      mimeTypeHint: "image/jpeg",
    }, { openWa: openWaMedia, meta: metaMedia });

    expect(metaMedia.download).toHaveBeenCalledWith({ providerMediaId: "META_MEDIA_ID_1", mimeTypeHint: "image/jpeg" });
    expect(openWaMedia.download).not.toHaveBeenCalled();
  });

  test("does not fetch media for text messages", async () => {
    const download = getMediaSelector();
    if (!download) return;
    const openWaMedia = { download: vi.fn() };
    const metaMedia = { download: vi.fn() };

    await expect(download({
      provider: "openwa",
      providerChannelId: "openwa-session-1",
      chatId: "201001234567@c.us",
      messageType: "text",
      mediaStatus: "not_applicable",
      providerMediaId: null,
      mimeTypeHint: null,
    }, { openWa: openWaMedia, meta: metaMedia })).resolves.toBeNull();
    expect(openWaMedia.download).not.toHaveBeenCalled();
    expect(metaMedia.download).not.toHaveBeenCalled();
  });

  test("fails closed for text from unknown providers without calling either media adapter", async () => {
    const download = getMediaSelector();
    if (!download) return;
    const openWaMedia = { download: vi.fn() };
    const metaMedia = { download: vi.fn() };

    await expect(download({
      provider: "unrecognized",
      providerChannelId: "channel",
      chatId: "201001234567@c.us",
      messageType: "text",
      mediaStatus: "not_applicable",
      providerMediaId: null,
      mimeTypeHint: null,
    }, { openWa: openWaMedia, meta: metaMedia })).rejects.toMatchObject({ message: "whatsapp_media_provider_unavailable" });
    expect(openWaMedia.download).not.toHaveBeenCalled();
    expect(metaMedia.download).not.toHaveBeenCalled();
  });

  test("fails closed for unknown providers without calling either media adapter", async () => {
    const download = getMediaSelector();
    if (!download) return;
    const openWaMedia = { download: vi.fn() };
    const metaMedia = { download: vi.fn() };

    await expect(download({
      provider: "unrecognized",
      providerChannelId: "channel",
      chatId: "201001234567@c.us",
      messageType: "image",
      mediaStatus: "pending",
      providerMediaId: "provider-message-id",
      mimeTypeHint: "image/jpeg",
    }, { openWa: openWaMedia, meta: metaMedia })).rejects.toMatchObject({ message: "whatsapp_media_provider_unavailable" });
    expect(openWaMedia.download).not.toHaveBeenCalled();
    expect(metaMedia.download).not.toHaveBeenCalled();
  });

  test("exports the strict WhatsApp generation request builder used by the Edge worker", () => {
    const request = buildWhatsappAiGenerationRequest({
      conversationType: "unknown",
      state,
      history: [],
      mediaMessageIds: [],
      dataClass: "synthetic",
    });

    expect(request.task).toBe("main");
    expect(request.dataClass).toBe("synthetic");
    expect(request.systemInstruction).toContain("conversationType, facts, missingFields, reply, recommendedAction, confidence");
  });

  test("builds a tenant/conversation/message-bound private intake path", () => {
    expect(buildWhatsappMediaStoragePath("org", "conversation", "message", "image/jpeg")).toBe("org/conversation/message.jpg");
    expect(buildWhatsappMediaStoragePath("org", "conversation", "message", "image/webp")).toBe("org/conversation/message.webp");
  });

  test("projects parsed facts and derives missing fields instead of trusting model questions", () => {
    const projected = projectWhatsappAiResponse(state, ownerResponse, "image-message-1");

    expect(projected.state.property?.monthlyPrice).toBe(35000);
    expect(projected.state.imageMessageIds).toEqual(["image-message-1"]);
    expect(projected.state.missingFields).toEqual(["owner.displayName", "property.availability"]);
    expect(projected.recommendedAction).toBe("continue");
  });

  test("does not send a reply when global outbound or auto-reply gates are disabled", () => {
    expect(shouldSendWhatsappReply({ ...ownerResponse, recommendedAction: "continue" }, { provider: "meta_cloud", outboundEnabled: false, autoRepliesEnabled: true })).toBe(false);
    expect(shouldSendWhatsappReply({ ...ownerResponse, recommendedAction: "continue" }, { provider: "meta_cloud", outboundEnabled: true, autoRepliesEnabled: false })).toBe(false);
    expect(shouldSendWhatsappReply({ ...ownerResponse, recommendedAction: "handoff" }, { provider: "meta_cloud", outboundEnabled: true, autoRepliesEnabled: true })).toBe(false);
    expect(shouldSendWhatsappReply(ownerResponse, { provider: "meta_cloud", outboundEnabled: true, autoRepliesEnabled: true })).toBe(true);
  });

  test("hard-disables OpenWA replies even when Meta and global reply gates are enabled", () => {
    const openWaFlags = { provider: "openwa", outboundEnabled: true, autoRepliesEnabled: true };
    const metaFlags = { provider: "meta_cloud_sandbox", outboundEnabled: true, autoRepliesEnabled: true };

    expect(shouldSendWhatsappReply(ownerResponse, openWaFlags)).toBe(false);
    expect(shouldSendWhatsappReply(ownerResponse, metaFlags)).toBe(true);
  });

  test("never auto-replies on low-confidence model output, even with open gates", () => {
    const lowConfidence = { ...ownerResponse, confidence: "low" } as const;
    expect(shouldSendWhatsappReply(lowConfidence, { provider: "meta_cloud", outboundEnabled: true, autoRepliesEnabled: true })).toBe(false);
    const mediumConfidence = { ...ownerResponse, confidence: "medium" } as const;
    expect(shouldSendWhatsappReply(mediumConfidence, { provider: "meta_cloud", outboundEnabled: true, autoRepliesEnabled: true })).toBe(true);
  });

  test("keeps transient pending media retryable until the final attempt", () => {
    expect(shouldMarkWhatsappMediaFailed(true, 1, 6)).toBe(false);
    expect(shouldMarkWhatsappMediaFailed(true, 6, 6)).toBe(true);
    expect(shouldMarkWhatsappMediaFailed(false, 1, 6)).toBe(true);
  });

  test("bounds and normalizes recent history without passing provider payloads through", () => {
    expect(toWhatsappHistory([
      { direction: "inbound", message_type: "text", body_text: "hello", caption: null, provider_media_id: "secret" },
      { direction: "outbound", message_type: "image", body_text: "صورة", caption: "caption" },
      { direction: "ignored", message_type: "text", body_text: "bad" },
    ])).toEqual([
      { direction: "inbound", messageType: "text", bodyText: "hello", caption: null },
      { direction: "outbound", messageType: "image", bodyText: "صورة", caption: "caption" },
    ]);
  });
});
