import { describe, expect, test, vi } from "vitest";
import * as whatsappAiWorker from "./whatsapp-ai-worker";
import { createOpenWaMediaAdapter } from "./openwa-media";
import { parseOpenWaMessageEvent } from "./openwa-webhook";
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
  requestIntent: "unclear",
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
  requestIntent: "unclear",
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

const completeClientLead = {
  name: null,
  phone: "+201000000000",
  whatsapp: "+201000000000",
  email: null,
  requestedArea: "Nasr City",
  checkIn: "2026-09-05",
  checkOut: "2026-09-10",
  guests: 5,
  bedrooms: 3,
  budgetText: "2500 EGP/day",
  notes: null,
  nextFollowUpAt: null,
};

const bookingRequestResponse: WhatsappAiResponse = {
  requestIntent: "booking_request",
  conversationType: "client_sales",
  facts: { language: "ar", owner: null, property: null, lead: completeClientLead },
  missingFields: [],
  reply: null,
  recommendedAction: "ready_for_review",
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

type StoreWhatsappMediaV1Input = Readonly<{
  p_event_id: string;
  p_worker_id: string;
  p_message_id: string;
  p_storage_path: string;
  p_mime_type: "image/jpeg" | "image/png" | "image/webp";
  p_byte_size: number;
  p_checksum_sha256: string;
}>;

type PendingImageWorkerInput = Readonly<{
  eventId: string;
  workerId: string;
  organizationId: string;
  conversationId: string;
  messageId: string;
  provider: string;
  providerChannelId: string | null;
  chatId: string | null;
  providerMediaId: string | null;
  mimeTypeHint: string | null;
}>;

type PendingImageWorkerDependencies = Readonly<{
  renewLease: () => Promise<boolean>;
  uploadPrivateObject: (input: Readonly<{
    bucket: "ai-intake";
    path: string;
    bytes: Uint8Array;
    contentType: string;
    upsert: false;
  }>) => Promise<boolean>;
  downloadPrivateObject: (bucket: "ai-intake", path: string) => Promise<Uint8Array | null>;
  storeWhatsappMediaV1: (input: StoreWhatsappMediaV1Input) => Promise<boolean>;
  sha256Hex: (bytes: Uint8Array) => Promise<string>;
  bytesToBase64: (bytes: Uint8Array) => string;
}>;

type PendingImageWorker = (
  input: PendingImageWorkerInput,
  adapters: MediaAdapterSet,
  dependencies: PendingImageWorkerDependencies,
) => Promise<Readonly<{
  imageParts: readonly Readonly<{ mimeType: string; data: string }>[];
  sourceImageMessageId: string | null;
}>>;

function getMediaSelector(): MediaSelector | undefined {
  const selector = (whatsappAiWorker as unknown as Record<string, unknown>).downloadWhatsappMediaForProvider;
  expect(selector).toBeTypeOf("function");
  return typeof selector === "function" ? selector as MediaSelector : undefined;
}

function getPendingImageWorker(): PendingImageWorker | undefined {
  const worker = (whatsappAiWorker as unknown as Record<string, unknown>).storePendingWhatsappImageForWorker;
  expect(worker).toBeTypeOf("function");
  return typeof worker === "function" ? worker as PendingImageWorker : undefined;
}

function copyBytesToArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}

async function sha256HexForTest(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", copyBytesToArrayBuffer(bytes));
  return Array.from(new Uint8Array(digest), (value) => value.toString(16).padStart(2, "0")).join("");
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

  test("stores an omitted-media OpenWA image through private ai-intake and the V1 media RPC", async () => {
    const parsed = parseOpenWaMessageEvent({
      event: "message.received",
      sessionId: "openwa-session-1",
      idempotencyKey: "omitted-image-event-1",
      data: {
        kind: "individual",
        isGroup: false,
        isStatusBroadcast: false,
        chatId: "201001234567@c.us",
        id: "OPENWA_WORKER_IMAGE_001",
        fromMe: false,
        type: "image",
        body: "Synthetic caption",
        media: { mimetype: "image/jpeg", omitted: true, sizeBytes: 5 },
        timestamp: 1_700_000_000,
      },
    });
    expect(parsed.kind).toBe("message");
    if (parsed.kind !== "message") return;
    expect(parsed.event.providerMediaId).toBe("OPENWA_WORKER_IMAGE_001");
    expect(parsed.event).not.toHaveProperty("media");

    const runWorker = getPendingImageWorker();
    if (!runWorker) return;

    const imageBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00]);
    const fetchRequests: Array<Readonly<[RequestInfo | URL, RequestInit?]>> = [];
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      fetchRequests.push([input, init]);
      return new Response(copyBytesToArrayBuffer(imageBytes), {
        status: 200,
        headers: { "content-type": "image/jpeg", "content-length": String(imageBytes.byteLength) },
      });
    });
    const openWaMedia = createOpenWaMediaAdapter({
      baseUrl: "https://openwa.example.test",
      apiKey: "synthetic-openwa-key",
      maxBytes: 1024,
      fetchImpl: fetchMock as unknown as typeof fetch,
    });
    const metaMedia = { download: vi.fn() };
    const privateObjects = new Map<string, Readonly<{ bytes: Uint8Array; contentType: string }>>();
    const mediaRows: StoreWhatsappMediaV1Input[] = [];
    let leaseRenewals = 0;
    const dependencies: PendingImageWorkerDependencies = {
      renewLease: async () => {
        leaseRenewals += 1;
        return true;
      },
      uploadPrivateObject: async ({ bucket, path, bytes, contentType }) => {
        const objectKey = `${bucket}/${path}`;
        if (privateObjects.has(objectKey)) return false;
        const copy = new Uint8Array(bytes.byteLength);
        copy.set(bytes);
        privateObjects.set(objectKey, { bytes: copy, contentType });
        return true;
      },
      downloadPrivateObject: async (bucket, path) => privateObjects.get(`${bucket}/${path}`)?.bytes ?? null,
      storeWhatsappMediaV1: async (input) => {
        mediaRows.push(input);
        return true;
      },
      sha256Hex: sha256HexForTest,
      bytesToBase64: (bytes) => Buffer.from(bytes).toString("base64"),
    };

    const result = await runWorker({
      eventId: "event-1",
      workerId: "worker-1",
      organizationId: "org-1",
      conversationId: "conversation-1",
      messageId: "message-internal-1",
      provider: "openwa",
      providerChannelId: parsed.event.sessionId,
      chatId: parsed.event.chatId,
      providerMediaId: parsed.event.providerMediaId,
      mimeTypeHint: parsed.event.mediaMimeHint,
    }, {
      openWa: openWaMedia,
      meta: metaMedia,
    }, dependencies);

    const expectedPath = "org-1/conversation-1/message-internal-1.jpg";
    const expectedChecksum = "f55517e918c9f1ac538778a7d787f93b66102886b93464e5bf61b48527913dfd";
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchRequests[0]?.[0]).toBe("https://openwa.example.test/api/sessions/openwa-session-1/messages/201001234567%40c.us/OPENWA_WORKER_IMAGE_001/media");
    expect(metaMedia.download).not.toHaveBeenCalled();
    expect(leaseRenewals).toBe(2);
    expect([...privateObjects.entries()]).toEqual([["ai-intake/org-1/conversation-1/message-internal-1.jpg", {
      bytes: imageBytes,
      contentType: "image/jpeg",
    }]]);
    expect(mediaRows).toEqual([{
      p_event_id: "event-1",
      p_worker_id: "worker-1",
      p_message_id: "message-internal-1",
      p_storage_path: expectedPath,
      p_mime_type: "image/jpeg",
      p_byte_size: imageBytes.byteLength,
      p_checksum_sha256: expectedChecksum,
    }]);
    expect(result).toEqual({
      imageParts: [{ mimeType: "image/jpeg", data: Buffer.from(imageBytes).toString("base64") }],
      sourceImageMessageId: "message-internal-1",
    });
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
    expect(request.systemInstruction).toContain("requestIntent, conversationType, facts, missingFields, reply, recommendedAction, confidence");
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

  test("keeps an incomplete booking proposal in progress and derives its missing lead fields", () => {
    const response: WhatsappAiResponse = {
      ...bookingRequestResponse,
      facts: {
        ...bookingRequestResponse.facts,
        lead: { ...completeClientLead, checkIn: null, checkOut: null, bedrooms: null, guests: null, budgetText: null },
      },
    };

    const projected = projectWhatsappAiResponse(state, response);

    expect(projected.state.requestIntent).toBe("booking_request");
    expect(projected.state.missingFields).toEqual(["lead.dates", "lead.bedrooms"]);
    expect(projected.recommendedAction).toBe("continue");
  });

  test("does not mark a low-confidence booking proposal ready for review", () => {
    const projected = projectWhatsappAiResponse(state, { ...bookingRequestResponse, confidence: "low" });

    expect(projected.state.missingFields).toEqual([]);
    expect(projected.recommendedAction).toBe("continue");
  });

  test("marks a complete high-confidence booking proposal ready for staff review", () => {
    const projected = projectWhatsappAiResponse(state, bookingRequestResponse);

    expect(projected.state.requestIntent).toBe("booking_request");
    expect(projected.state.missingFields).toEqual([]);
    expect(projected.recommendedAction).toBe("ready_for_review");
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
