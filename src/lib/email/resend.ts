import type { EmailDeliveryRequest, ProviderDeliveryResult } from "../outbox/dispatch-contract";

type ResendAdapterOptions = Readonly<{
  apiKey: string;
  from: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}>;

export type ResendDeliveryResult = ProviderDeliveryResult & Readonly<{ providerMessageId?: string }>;

type ResendResponse = Readonly<{ id?: string }>;

export function createResendEmailAdapter(options: ResendAdapterOptions) {
  const apiKey = options.apiKey.trim();
  const from = options.from.trim();
  if (!apiKey || !from) throw new Error("Resend adapter requires an API key and sender.");
  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = Math.min(Math.max(options.timeoutMs ?? 10_000, 1_000), 30_000);

  return {
    async send(request: EmailDeliveryRequest): Promise<ResendDeliveryResult> {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await fetchImpl("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            authorization: `Bearer ${apiKey}`,
            "content-type": "application/json",
            "idempotency-key": request.idempotencyKey,
          },
          body: JSON.stringify({
            from,
            to: [request.to],
            subject: request.subject,
            text: request.text,
            html: request.html,
          }),
          signal: controller.signal,
        });
        if (response.status === 429) return { kind: "retryable", errorCode: "email_rate_limited" };
        if (response.status >= 500) return { kind: "retryable", errorCode: "email_provider_error" };
        if (!response.ok) return { kind: "permanent", errorCode: "email_rejected" };
        const payload = await response.json() as ResendResponse;
        const providerMessageId = typeof payload.id === "string" && payload.id.trim() ? payload.id.trim() : undefined;
        return providerMessageId
          ? { kind: "delivered", providerMessageId }
          : { kind: "permanent", errorCode: "email_invalid_response" };
      } catch (error) {
        if (error instanceof Error && error.name === "AbortError") return { kind: "ambiguous", errorCode: "email_provider_timeout" };
        return { kind: "ambiguous", errorCode: "email_provider_unreachable" };
      } finally {
        clearTimeout(timer);
      }
    },
  };
}
