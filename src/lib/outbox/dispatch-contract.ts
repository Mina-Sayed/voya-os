export type OutboxEvent = Readonly<{
  id: string;
  event_type: string;
  schema_version: number;
  attempts: number;
  payload: Readonly<Record<string, unknown>>;
}>;

export type EmailDeliveryRequest = Readonly<{
  to: string;
  subject: string;
  text: string;
  html: string;
  idempotencyKey: string;
}>;

export type MetaWhatsAppProvider = "meta_cloud" | "meta_cloud_sandbox";

export type MetaWhatsAppDeliveryRequest = Readonly<{
  provider: MetaWhatsAppProvider;
  phoneNumberId: string;
  to: string;
  body: string;
  idempotencyKey: string;
}>;

export type OpenWaWhatsAppDeliveryRequest = Readonly<{
  provider: "openwa";
  sessionId: string;
  chatId: string;
  body: string;
  idempotencyKey: string;
}>;

export type WhatsAppDeliveryRequest = MetaWhatsAppDeliveryRequest | OpenWaWhatsAppDeliveryRequest;

export type ProviderDeliveryResult = Readonly<{
  kind: "delivered" | "retryable" | "ambiguous" | "permanent";
  errorCode?: string;
  providerMessageId?: string;
}>;

export type OutboxDispatchResult = Readonly<{
  outcome: "completed" | "retry" | "needs_review" | "dead_letter";
  errorCode?: string;
  retryAfterSeconds?: number;
  providerMessageId?: string;
}>;

export type OutboxDispatchDependencies = Readonly<{
  emailEnabled: boolean;
  whatsappEnabled: boolean;
  openWaEnabled: boolean;
  applicationUrl: string;
  sendEmail: (request: EmailDeliveryRequest) => Promise<ProviderDeliveryResult>;
  renewWhatsAppLease: () => Promise<boolean>;
  sendWhatsApp: (request: WhatsAppDeliveryRequest) => Promise<ProviderDeliveryResult>;
}>;

const retryDelaysSeconds = [60, 300, 900, 3600, 21600] as const;

export function getOutboxRetryDelaySeconds(attempts: number): number | null {
  if (!Number.isInteger(attempts) || attempts < 1 || attempts > retryDelaysSeconds.length) return null;
  return retryDelaysSeconds[attempts - 1] ?? null;
}

function textValue(payload: Readonly<Record<string, unknown>>, key: string): string | null {
  const value = payload[key];
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function providerErrorCode(result: ProviderDeliveryResult, fallback: string): string {
  const candidate = result.errorCode?.trim();
  return candidate && /^[a-z][a-z0-9_.-]{0,119}$/u.test(candidate) ? candidate : fallback;
}

function boundedIdentifier(value: unknown, maximum: number): value is string {
  return typeof value === "string"
    && value.length >= 1
    && value.length <= maximum
    && value === value.trim()
    && !/[\u0000-\u0020\u007f]/u.test(value);
}

function validOpenWaChatId(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9._:-]{1,250}@(c\.us|lid)$/u.test(value);
}

function validMetaPhone(value: unknown): value is string {
  return typeof value === "string" && /^\+?[1-9][0-9]{6,14}$/u.test(value);
}

function validProviderMessageId(value: unknown): value is string {
  return boundedIdentifier(value, 320);
}

function mapProviderResult(result: ProviderDeliveryResult, attempts: number): OutboxDispatchResult {
  if (result.kind === "delivered") return { outcome: "completed", ...(result.providerMessageId ? { providerMessageId: result.providerMessageId } : {}) };
  const errorCode = providerErrorCode(result, "provider_failure");
  if (result.kind === "ambiguous") return { outcome: "needs_review", errorCode };
  if (result.kind === "permanent") return { outcome: "dead_letter", errorCode };
  const retryAfterSeconds = getOutboxRetryDelaySeconds(attempts);
  return retryAfterSeconds === null
    ? { outcome: "dead_letter", errorCode }
    : { outcome: "retry", errorCode, retryAfterSeconds };
}

function invitationEmail(event: OutboxEvent, applicationUrl: string): EmailDeliveryRequest | OutboxDispatchResult {
  const email = textValue(event.payload, "email");
  const token = textValue(event.payload, "token");
  const role = textValue(event.payload, "role") ?? "operator";
  if (!email || !token) return { outcome: "needs_review", errorCode: "invitation_payload_incomplete" };
  const invitationUrl = `${applicationUrl.replace(/\/$/u, "")}/invite?token=${encodeURIComponent(token)}`;
  return {
    to: email,
    subject: "دعوة للانضمام إلى مساحة Voya OS",
    text: `تمت دعوتك للانضمام إلى مساحة العمل بدور ${role}. افتح الرابط: ${invitationUrl}`,
    html: `<p>تمت دعوتك للانضمام إلى مساحة العمل بدور <strong>${role}</strong>.</p><p><a href="${invitationUrl}">فتح الدعوة</a></p>`,
    idempotencyKey: event.id,
  };
}

export async function dispatchOutboxEvent(
  event: OutboxEvent,
  dependencies: OutboxDispatchDependencies,
): Promise<OutboxDispatchResult> {
  if (event.schema_version !== 1) return { outcome: "needs_review", errorCode: "unsupported_schema_version" };

  if (event.event_type === "organization.invitation.send_requested" || event.event_type === "member.invitation.resent") {
    if (!dependencies.emailEnabled) return { outcome: "needs_review", errorCode: "email_delivery_disabled" };
    const request = invitationEmail(event, dependencies.applicationUrl);
    if ("outcome" in request) return request;
    return mapProviderResult(await dependencies.sendEmail(request), event.attempts);
  }

  if (event.event_type === "whatsapp.message.send_requested") {
    if (!dependencies.whatsappEnabled) return { outcome: "needs_review", errorCode: "whatsapp_delivery_disabled" };
    const provider = event.payload.provider;
    const body = event.payload.body;
    if (typeof body !== "string" || !body.trim() || body.length > 4096) {
      return { outcome: "needs_review", errorCode: "whatsapp_payload_incomplete" };
    }

    let request: WhatsAppDeliveryRequest;
    if (provider === "meta_cloud" || provider === "meta_cloud_sandbox") {
      const phoneNumberId = event.payload.providerChannelId;
      const recipientPhone = event.payload.recipientPhone;
      if (!boundedIdentifier(phoneNumberId, 256) || !validMetaPhone(recipientPhone)) {
        return { outcome: "needs_review", errorCode: "whatsapp_destination_invalid" };
      }
      request = { provider, phoneNumberId, to: recipientPhone, body, idempotencyKey: event.id };
    } else if (provider === "openwa") {
      if (!dependencies.openWaEnabled) return { outcome: "needs_review", errorCode: "openwa_delivery_disabled" };
      const sessionId = event.payload.providerChannelId;
      const chatId = event.payload.chatId;
      if (!boundedIdentifier(sessionId, 256) || !validOpenWaChatId(chatId)) {
        return { outcome: "needs_review", errorCode: "whatsapp_destination_invalid" };
      }
      request = { provider, sessionId, chatId, body, idempotencyKey: event.id };
    } else {
      return { outcome: "needs_review", errorCode: "whatsapp_provider_unknown" };
    }

    let leaseLive = false;
    try {
      leaseLive = await dependencies.renewWhatsAppLease();
    } catch {
      leaseLive = false;
    }
    if (!leaseLive) return { outcome: "needs_review", errorCode: "outbox_lease_lost" };

    let providerResult: ProviderDeliveryResult;
    try {
      providerResult = await dependencies.sendWhatsApp(request);
    } catch {
      return { outcome: "needs_review", errorCode: "whatsapp_delivery_unknown" };
    }
    if (providerResult.kind === "delivered" && !validProviderMessageId(providerResult.providerMessageId)) {
      return { outcome: "needs_review", errorCode: "whatsapp_provider_id_missing" };
    }
    return mapProviderResult(providerResult, event.attempts);
  }

  return { outcome: "needs_review", errorCode: "unsupported_outbox_event" };
}
