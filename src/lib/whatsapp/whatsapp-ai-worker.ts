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
  response: Pick<WhatsappAiResponse, "recommendedAction" | "reply" | "confidence">,
  flags: Readonly<{ provider: string; outboundEnabled: boolean; autoRepliesEnabled: boolean }>,
): boolean {
  return (flags.provider === "meta_cloud" || flags.provider === "meta_cloud_sandbox")
    && flags.outboundEnabled
    && flags.autoRepliesEnabled
    && response.confidence !== "low"
    && response.recommendedAction !== "handoff"
    && response.recommendedAction !== "no_reply"
    && typeof response.reply === "string"
    && response.reply.trim().length > 0;
}

export function shouldMarkWhatsappMediaFailed(isRetryable: boolean, attempts: number, maxAttempts: number): boolean {
  return !isRetryable || attempts >= maxAttempts;
}

type SupportedWhatsappImageMime = "image/jpeg" | "image/png" | "image/webp";

type WhatsappMediaAsset = Readonly<{
  mimeType: SupportedWhatsappImageMime;
  sizeBytes: number;
  bytes: Uint8Array;
}>;

type WhatsappMediaProviderInput = Readonly<{
  provider: string;
  providerChannelId: string | null;
  chatId: string | null;
  messageType: string;
  mediaStatus: string;
  providerMediaId: string | null;
  mimeTypeHint: string | null;
}>;

type WhatsappMediaProviderAdapters = Readonly<{
  openWa: Readonly<{
    download(request: Readonly<{
      sessionId: string;
      chatId: string;
      messageId: string;
      mimeTypeHint: SupportedWhatsappImageMime | null;
    }>): Promise<WhatsappMediaAsset>;
  }> | null;
  meta: Readonly<{
    download(request: Readonly<{
      providerMediaId: string;
      mimeTypeHint: SupportedWhatsappImageMime | null;
    }>): Promise<WhatsappMediaAsset>;
  }> | null;
}>;

function supportedMediaHint(value: string | null): SupportedWhatsappImageMime | null {
  if (value === null) return null;
  if (value === "image/jpeg" || value === "image/png" || value === "image/webp") return value;
  throw new Error("whatsapp_media_unsupported_type");
}

function trustedMediaIdentifier(value: string | null, maximum: number): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maximum || value !== value.trim()) {
    throw new Error("whatsapp_media_invalid_response");
  }
  return value;
}

function isOpenWaDirectChatId(value: string): boolean {
  return /^[A-Za-z0-9._:-]{1,250}@(c\.us|lid)$/u.test(value);
}

export async function downloadWhatsappMediaForProvider(
  input: WhatsappMediaProviderInput,
  adapters: WhatsappMediaProviderAdapters,
  beforeDownload?: () => Promise<boolean>,
): Promise<WhatsappMediaAsset | null> {
  if (input.provider !== "openwa" && input.provider !== "meta_cloud" && input.provider !== "meta_cloud_sandbox") {
    throw new Error("whatsapp_media_provider_unavailable");
  }
  if (input.messageType !== "image") return null;
  if (input.mediaStatus === "stored") return null;
  if (input.mediaStatus !== "pending") throw new Error("whatsapp_media_invalid_response");

  const providerMediaId = trustedMediaIdentifier(input.providerMediaId, 320);
  const mimeTypeHint = supportedMediaHint(input.mimeTypeHint);

  if (input.provider === "openwa") {
    const sessionId = trustedMediaIdentifier(input.providerChannelId, 256);
    const chatId = trustedMediaIdentifier(input.chatId, 256);
    if (!isOpenWaDirectChatId(chatId)) throw new Error("whatsapp_media_invalid_request");
    if (!adapters.openWa) throw new Error("whatsapp_media_provider_unavailable");
    if (beforeDownload && !(await beforeDownload())) throw new Error("whatsapp_media_timeout");
    return adapters.openWa.download({
      sessionId,
      chatId,
      messageId: providerMediaId,
      mimeTypeHint,
    });
  }

  if (!adapters.meta) throw new Error("whatsapp_media_provider_unavailable");
  if (beforeDownload && !(await beforeDownload())) throw new Error("whatsapp_media_timeout");
  return adapters.meta.download({ providerMediaId, mimeTypeHint });
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
