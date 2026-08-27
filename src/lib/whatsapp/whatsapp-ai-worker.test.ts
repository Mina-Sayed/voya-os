import { describe, expect, test } from "vitest";
import {
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

describe("WhatsApp AI worker helpers", () => {
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
    expect(shouldSendWhatsappReply({ ...ownerResponse, recommendedAction: "continue" }, { outboundEnabled: false, autoRepliesEnabled: true })).toBe(false);
    expect(shouldSendWhatsappReply({ ...ownerResponse, recommendedAction: "continue" }, { outboundEnabled: true, autoRepliesEnabled: false })).toBe(false);
    expect(shouldSendWhatsappReply({ ...ownerResponse, recommendedAction: "handoff" }, { outboundEnabled: true, autoRepliesEnabled: true })).toBe(false);
    expect(shouldSendWhatsappReply(ownerResponse, { outboundEnabled: true, autoRepliesEnabled: true })).toBe(true);
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
