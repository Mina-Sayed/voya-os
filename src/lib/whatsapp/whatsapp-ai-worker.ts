import type { GeminiGenerationResult } from "../ai/gemini-runtime.ts";
import { buildWhatsappAiGenerationRequest, deriveWhatsappMissingFields, mergeWhatsappConversationState, normalizeWhatsappConversationState, type WhatsappAiResponse, type WhatsappConversationState, type WhatsappHistoryItem } from "../../domain/ai/whatsapp-agent-contract.ts";

export { buildWhatsappAiGenerationRequest };

type UnknownRecord = Record<string, unknown>;

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function text(value: unknown, maximum = 2_000): string | null {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, maximum) : null;
}

export function buildWhatsappMediaStoragePath(
  organizationId: string,
  conversationId: string,
  messageId: string,
  mimeType: "image/jpeg" | "image/png" | "image/webp",
): string {
  const extension = mimeType === "image/jpeg" ? "jpg" : mimeType === "image/png" ? "png" : "webp";
  return `${organizationId}/${conversationId}/${messageId}.${extension}`.toLowerCase();
}

export function toWhatsappHistory(input: unknown): readonly WhatsappHistoryItem[] {
  if (!Array.isArray(input)) return [];
  return input.flatMap((value): WhatsappHistoryItem[] => {
    if (!isRecord(value)) return [];
    const direction = value.direction === "inbound" || value.direction === "outbound" ? value.direction : null;
    const messageType = value.message_type === "text" || value.message_type === "image" ? value.message_type : null;
    const bodyText = text(value.body_text);
    if (!direction || !messageType || !bodyText) return [];
    return [{ direction, messageType, bodyText, caption: text(value.caption) }];
  }).slice(-20);
}

export function projectWhatsappAiResponse(
  current: WhatsappConversationState,
  response: WhatsappAiResponse,
  sourceImageMessageId?: string,
): Readonly<{
  state: WhatsappConversationState;
  recommendedAction: WhatsappAiResponse["recommendedAction"];
}> {
  const proposal: WhatsappConversationState = {
    language: response.facts.language ?? current.language,
    owner: response.facts.owner,
    property: response.facts.property,
    lead: response.facts.lead,
    missingFields: [],
    confidence: response.confidence,
    imageMessageIds: sourceImageMessageId ? [sourceImageMessageId] : [],
  };
  const merged = mergeWhatsappConversationState(current, proposal);
  const missingFields = deriveWhatsappMissingFields(response.conversationType, merged);
  const recommendedAction = response.recommendedAction === "ready_for_review" && missingFields.length > 0
    ? "continue"
    : response.recommendedAction;
  return { state: { ...merged, missingFields }, recommendedAction };
}

export function shouldSendWhatsappReply(
  response: Pick<WhatsappAiResponse, "recommendedAction" | "reply">,
  flags: Readonly<{ outboundEnabled: boolean; autoRepliesEnabled: boolean }>,
): boolean {
  return flags.outboundEnabled
    && flags.autoRepliesEnabled
    && response.recommendedAction !== "handoff"
    && response.recommendedAction !== "no_reply"
    && typeof response.reply === "string"
    && response.reply.trim().length > 0;
}

export function shouldMarkWhatsappMediaFailed(isRetryable: boolean, attempts: number, maxAttempts: number): boolean {
  return !isRetryable || attempts >= maxAttempts;
}

export function summarizeWhatsappAiResult(
  result: GeminiGenerationResult,
  response: Pick<WhatsappAiResponse, "conversationType" | "recommendedAction" | "confidence">,
): Readonly<{ provider: GeminiGenerationResult["provider"]; model: string; conversationType: string; recommendedAction: string; confidence: string }> {
  return {
    provider: result.provider,
    model: result.model,
    conversationType: response.conversationType,
    recommendedAction: response.recommendedAction,
    confidence: response.confidence,
  };
}

export function readStoredWhatsappState(value: unknown, sourceText = ""): WhatsappConversationState {
  return normalizeWhatsappConversationState(value, sourceText);
}
