import { createHash, createHmac, timingSafeEqual } from "node:crypto";

export type OpenWaMessageEvent = Readonly<{
  sessionId: string;
  chatId: string;
  messageId: string;
  eventKey: string;
  direction: "inbound" | "outbound";
  contactJid: string;
  contactPhone: string | null;
  contactDisplay: string | null;
  messageType: "text" | "image";
  bodyText: string | null;
  providerMediaId: string | null;
  mediaMimeHint: "image/jpeg" | "image/png" | "image/webp" | null;
  caption: string | null;
  receivedAt: string | null;
}>;

export type OpenWaParseResult =
  | Readonly<{ kind: "ignored" }>
  | Readonly<{ kind: "message"; event: OpenWaMessageEvent }>;

type UnknownRecord = Readonly<Record<string, unknown>>;

const IGNORED: OpenWaParseResult = Object.freeze({ kind: "ignored" });

function record(value: unknown): UnknownRecord | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as UnknownRecord
    : null;
}

function boundedString(value: unknown, maximum: number): string | null {
  if (typeof value !== "string" || value.length > maximum) return null;
  const normalized = value.trim();
  return normalized.length > 0 ? normalized : null;
}

function canonicalString(value: unknown, maximum: number): string | null {
  if (typeof value !== "string" || value.length === 0 || value.length > maximum || value !== value.trim()) return null;
  return value;
}

function optionalString(value: unknown, maximum: number): string | null | undefined {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || value.length > maximum) return undefined;
  const normalized = value.trim();
  return normalized.length > 0 ? normalized : null;
}

function isDirectChatJid(value: string): boolean {
  return /^[A-Za-z0-9._:-]{1,250}@(c\.us|lid)$/u.test(value);
}

function validatedPhone(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const phone = value.trim();
  return /^\d{7,15}$/u.test(phone) ? phone : null;
}

function phoneFromChatJid(chatId: string): string | null {
  if (!chatId.endsWith("@c.us")) return null;
  return validatedPhone(chatId.slice(0, -"@c.us".length));
}

function normalizedTimestamp(value: unknown): string | null {
  let milliseconds: number;
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) return null;
    milliseconds = value >= 100_000_000_000 ? value : value * 1_000;
  } else if (typeof value === "string") {
    const timestamp = value.trim();
    if (timestamp.length === 0 || timestamp.length > 40) return null;
    if (/^\d{1,13}$/u.test(timestamp)) {
      const numeric = Number(timestamp);
      milliseconds = numeric >= 100_000_000_000 ? numeric : numeric * 1_000;
    } else {
      milliseconds = Date.parse(timestamp);
    }
  } else {
    return null;
  }

  if (!Number.isFinite(milliseconds) || Math.abs(milliseconds) > 8.64e15) return null;
  const date = new Date(milliseconds);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function eventKeyFor(sessionId: string, idempotencyKey: string): string {
  const signedIdentity = JSON.stringify([sessionId, idempotencyKey]);
  const digest = createHash("sha256").update(signedIdentity, "utf8").digest("hex");
  return `openwa:${digest}`;
}

export function verifyOpenWaSignature(
  rawBytes: Uint8Array,
  signature: string | null,
  secret: string,
): boolean {
  if (!signature || typeof secret !== "string" || secret.length === 0) return false;
  const supplied = signature.trim().replace(/^sha256=/iu, "");
  if (!/^[a-f0-9]{64}$/iu.test(supplied)) return false;

  const expectedBytes = createHmac("sha256", secret).update(rawBytes).digest();
  const suppliedBytes = Buffer.from(supplied, "hex");
  return suppliedBytes.length === expectedBytes.length && timingSafeEqual(expectedBytes, suppliedBytes);
}

export function parseOpenWaMessageEvent(payload: unknown): OpenWaParseResult {
  const root = record(payload);
  if (!root) return IGNORED;

  const eventName = root.event;
  if (eventName !== "message.received" && eventName !== "message.sent") return IGNORED;
  const sessionId = canonicalString(root.sessionId, 256);
  const idempotencyKey = canonicalString(root.idempotencyKey, 320);
  const data = record(root.data);
  if (!sessionId || !idempotencyKey || !data) return IGNORED;

  if (data.kind !== "individual" || data.isGroup !== false || data.isStatusBroadcast === true) return IGNORED;
  const chatId = canonicalString(data.chatId, 256);
  const messageId = canonicalString(data.id, 320);
  if (!chatId || !isDirectChatJid(chatId) || !messageId) return IGNORED;

  const direction = eventName === "message.received" ? "inbound" : "outbound";
  if ((direction === "inbound" && data.fromMe !== false) || (direction === "outbound" && data.fromMe !== true)) return IGNORED;

  const messageType = data.type;
  if (messageType !== "text" && messageType !== "image") return IGNORED;

  const contact = record(data.contact);
  const contactDisplay = direction === "inbound"
    ? optionalString(contact?.pushName ?? contact?.name, 160)
    : null;
  if (contactDisplay === undefined) return IGNORED;

  const contactPhone = phoneFromChatJid(chatId)
    ?? (direction === "inbound" && chatId.endsWith("@lid")
      ? validatedPhone(data.senderPhone)
      : null);
  const receivedAt = normalizedTimestamp(data.timestamp) ?? normalizedTimestamp(root.timestamp);
  const common = {
    sessionId,
    chatId,
    messageId,
    eventKey: eventKeyFor(sessionId, idempotencyKey),
    direction,
    contactJid: chatId,
    contactPhone,
    contactDisplay,
    receivedAt,
  } as const;

  if (messageType === "text") {
    const bodyText = boundedString(data.body, 4_096);
    if (!bodyText) return IGNORED;
    return {
      kind: "message",
      event: {
        ...common,
        messageType,
        bodyText,
        providerMediaId: null,
        mediaMimeHint: null,
        caption: null,
      },
    };
  }

  const media = record(data.media);
  if (!media || media.omitted !== true || media.data !== undefined) return IGNORED;
  const mimeValue = optionalString(media.mimetype, 128);
  if (mimeValue === undefined) return IGNORED;
  const normalizedMime = mimeValue?.toLowerCase() ?? null;
  let mediaMimeHint: OpenWaMessageEvent["mediaMimeHint"] = null;
  if (normalizedMime === "image/jpeg" || normalizedMime === "image/png" || normalizedMime === "image/webp") {
    mediaMimeHint = normalizedMime;
  } else if (normalizedMime !== null) {
    return IGNORED;
  }
  const caption = optionalString(data.body, 4_096);
  if (caption === undefined) return IGNORED;

  return {
    kind: "message",
    event: {
      ...common,
      messageType,
      bodyText: null,
      providerMediaId: messageId,
      mediaMimeHint,
      caption,
    },
  };
}
