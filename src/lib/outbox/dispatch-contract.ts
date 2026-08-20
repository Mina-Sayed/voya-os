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

export type WhatsAppDeliveryRequest = Readonly<{
  phoneNumberId: string;
  to: string;
  body: string;
  idempotencyKey: string;
}>;

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
  applicationUrl: string;
  sendEmail: (request: EmailDeliveryRequest) => Promise<ProviderDeliveryResult>;
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
    const phoneNumberId = textValue(event.payload, "phoneNumberId");
    const to = textValue(event.payload, "to");
    const body = textValue(event.payload, "body");
    if (!phoneNumberId || !to || !body) return { outcome: "needs_review", errorCode: "whatsapp_payload_incomplete" };
    return mapProviderResult(await dependencies.sendWhatsApp({ phoneNumberId, to, body, idempotencyKey: event.id }), event.attempts);
  }

  return { outcome: "needs_review", errorCode: "unsupported_outbox_event" };
}
