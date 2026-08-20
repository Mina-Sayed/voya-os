import type { ProviderDeliveryResult, WhatsAppDeliveryRequest } from "../outbox/dispatch-contract";

type MetaWhatsAppAdapterOptions = Readonly<{
  accessToken: string;
  graphApiVersion: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}>;

export type MetaWhatsAppDeliveryResult = ProviderDeliveryResult & Readonly<{ providerMessageId?: string }>;

type MetaResponse = Readonly<{ messages?: readonly Readonly<{ id?: string }>[] }>;

export function createMetaWhatsAppOutboundAdapter(options: MetaWhatsAppAdapterOptions) {
  const accessToken = options.accessToken.trim();
  const graphApiVersion = options.graphApiVersion.trim();
  if (!accessToken || !graphApiVersion || !/^v[0-9]+(?:\.[0-9]+)?$/u.test(graphApiVersion)) {
    throw new Error("WhatsApp adapter requires an access token and Graph API version.");
  }
  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = Math.min(Math.max(options.timeoutMs ?? 10_000, 1_000), 30_000);

  return {
    async send(request: WhatsAppDeliveryRequest): Promise<MetaWhatsAppDeliveryResult> {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await fetchImpl(
          `https://graph.facebook.com/${graphApiVersion}/${encodeURIComponent(request.phoneNumberId)}/messages`,
          {
            method: "POST",
            headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
            body: JSON.stringify({ messaging_product: "whatsapp", to: request.to, type: "text", text: { body: request.body } }),
            signal: controller.signal,
          },
        );
        if (response.status === 429) return { kind: "retryable", errorCode: "whatsapp_rate_limited" };
        if (response.status >= 500) return { kind: "retryable", errorCode: "whatsapp_provider_error" };
        if (!response.ok) return { kind: "permanent", errorCode: "whatsapp_rejected" };
        const payload = await response.json() as MetaResponse;
        const providerMessageId = payload.messages?.[0]?.id;
        return typeof providerMessageId === "string" && providerMessageId.trim()
          ? { kind: "delivered", providerMessageId: providerMessageId.trim() }
          : { kind: "permanent", errorCode: "whatsapp_invalid_response" };
      } catch (error) {
        if (error instanceof Error && error.name === "AbortError") return { kind: "ambiguous", errorCode: "whatsapp_provider_timeout" };
        return { kind: "ambiguous", errorCode: "whatsapp_provider_unreachable" };
      } finally {
        clearTimeout(timer);
      }
    },
  };
}
