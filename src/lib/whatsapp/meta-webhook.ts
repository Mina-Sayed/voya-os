import { createHmac, timingSafeEqual } from "node:crypto";

export type InboundWhatsAppEvent = Readonly<{
  provider: "meta_cloud_sandbox" | "meta_cloud";
  externalChannelId: string;
  externalConversationKey: string;
  eventKey: string;
  senderPhone: string;
  bodyText: string;
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
        if (message?.type !== "text") continue;
        const eventKey = boundedString(message?.id, 320);
        const senderPhone = boundedString(message?.from, 80);
        const text = record(message?.text);
        const bodyText = boundedString(text?.body, 4096);
        if (!eventKey || !senderPhone || !bodyText) continue;
        const provider = change?.field === "messages" ? "meta_cloud" : "meta_cloud_sandbox";
        events.push({ provider, externalChannelId, externalConversationKey: senderPhone, eventKey, senderPhone, bodyText });
      }
    }
  }
  return events;
}
