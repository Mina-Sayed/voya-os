import { createHmac, timingSafeEqual } from "node:crypto";

export type InboundWhatsAppEvent = Readonly<{
  provider: "meta_cloud_sandbox" | "meta_cloud";
  externalChannelId: string;
  externalConversationKey: string;
  eventKey: string;
  senderPhone: string;
  messageType: "text" | "image";
  bodyText: string | null;
  providerMediaId: string | null;
  mediaMimeTypeHint: "image/jpeg" | "image/png" | "image/webp" | null;
  caption: string | null;
  receivedAt: string | null;
}>;

export function verifyMetaWebhookSignature(rawBody: string, signatureHeader: string | null, appSecret: string): boolean {
  if (!signatureHeader || !appSecret.trim()) return false;
  const supplied = signatureHeader.trim().replace(/^sha256=/i, "");
  if (!/^[a-f0-9]{64}$/i.test(supplied)) return false;
  const expected = createHmac("sha256", appSecret).update(rawBody, "utf8").digest("hex");
  return timingSafeEqual(Buffer.from(expected, "hex"), Buffer.from(supplied, "hex"));
}

type UnknownRecord = Readonly<Record<string, unknown>>;

function record(value: unknown): UnknownRecord | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as UnknownRecord : null;
}

function boundedString(value: unknown, maximum: number): string | null {
  return typeof value === "string" && value.trim().length > 0 && value.trim().length <= maximum ? value.trim() : null;
}

function boundedOptionalString(value: unknown, maximum: number): string | null {
  return typeof value === "string" && value.trim().length > 0 && value.trim().length <= maximum ? value.trim() : null;
}

function receivedAt(value: unknown): string | null {
  const timestamp = typeof value === "number" ? String(value) : boundedString(value, 11);
  if (!timestamp || !/^\d{1,11}$/u.test(timestamp)) return null;
  const milliseconds = Number(timestamp) * 1_000;
  if (!Number.isSafeInteger(milliseconds)) return null;
  const date = new Date(milliseconds);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function imageMimeTypeHint(value: unknown): InboundWhatsAppEvent["mediaMimeTypeHint"] {
  const mimeType = boundedOptionalString(value, 128)?.toLowerCase() ?? null;
  return mimeType === "image/jpeg" || mimeType === "image/png" || mimeType === "image/webp" ? mimeType : null;
}

export function parseInboundWhatsAppEvents(payload: unknown): readonly InboundWhatsAppEvent[] {
  const root = record(payload);
  const entries = Array.isArray(root?.entry) ? root.entry : [];
  const events: InboundWhatsAppEvent[] = [];
  for (const entryValue of entries) {
    const entry = record(entryValue);
    const changes = Array.isArray(entry?.changes) ? entry.changes : [];
    for (const changeValue of changes) {
      const change = record(changeValue);
      const value = record(change?.value);
      const metadata = record(value?.metadata);
      const externalChannelId = boundedString(metadata?.phone_number_id, 256);
      const messages = Array.isArray(value?.messages) ? value.messages : [];
      if (!externalChannelId) continue;
      for (const messageValue of messages) {
        const message = record(messageValue);
        const eventKey = boundedString(message?.id, 320);
        const senderPhone = boundedString(message?.from, 80);
        if (!eventKey || !senderPhone) continue;
        const provider = change?.field === "messages" ? "meta_cloud" : "meta_cloud_sandbox";
        const base = {
          provider,
          externalChannelId,
          externalConversationKey: senderPhone,
          eventKey,
          senderPhone,
          receivedAt: receivedAt(message?.timestamp),
        } as const;

        if (message?.type === "text") {
          const text = record(message.text);
          const bodyText = boundedString(text?.body, 4096);
          if (!bodyText) continue;
          events.push({
            ...base,
            messageType: "text",
            bodyText,
            providerMediaId: null,
            mediaMimeTypeHint: null,
            caption: null,
          });
          continue;
        }

        if (message?.type !== "image") continue;
        const image = record(message.image);
        const providerMediaId = boundedString(image?.id, 320);
        const mediaMimeTypeHint = imageMimeTypeHint(image?.mime_type);
        if (!providerMediaId || (image?.mime_type !== undefined && !mediaMimeTypeHint)) continue;
        events.push({
          ...base,
          messageType: "image",
          bodyText: null,
          providerMediaId,
          mediaMimeTypeHint,
          caption: boundedOptionalString(image?.caption, 4_096),
        });
      }
    }
  }
  return events;
}
