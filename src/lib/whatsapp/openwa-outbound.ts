import type {
  OpenWaWhatsAppDeliveryRequest,
  ProviderDeliveryResult,
} from "../outbox/dispatch-contract.ts";

type OpenWaOutboundAdapterOptions = Readonly<{
  baseUrl: string;
  apiKey: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}>;

type OpenWaSendResponse = Readonly<{ messageId?: unknown }>;

function isLiteralLoopbackHost(hostname: string): boolean {
  return hostname === "127.0.0.1" || hostname === "[::1]";
}

function normalizeBaseUrl(value: string): string {
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    throw new Error("OpenWA outbound adapter requires a valid root URL.");
  }

  if (url.protocol === "http:" && !isLiteralLoopbackHost(url.hostname)) {
    throw new Error("HTTPS is required for OpenWA outbound outside loopback.");
  }
  if ((url.protocol !== "https:" && url.protocol !== "http:")
    || url.pathname !== "/" || url.search || url.hash || url.username || url.password) {
    throw new Error("OpenWA outbound adapter requires a valid root URL.");
  }
  return url.toString().replace(/\/$/u, "");
}

function validSessionId(value: string): boolean {
  return value.length >= 1
    && value.length <= 256
    && value === value.trim()
    && !/[\u0000-\u0020\u007f]/u.test(value);
}

function normalizeChatId(value: string): string | null {
  if (!value || value.length > 256 || value !== value.trim()) return null;
  if (/^\+?[1-9][0-9]{6,14}$/u.test(value)) return `${value.replace(/^\+/u, "")}@c.us`;
  if (/^[A-Za-z0-9._:-]{1,250}@(c\.us|lid)$/u.test(value)) return value;
  return null;
}

function validMessageId(value: unknown): value is string {
  return typeof value === "string"
    && value.length >= 1
    && value.length <= 320
    && value === value.trim()
    && !/[\u0000-\u001f\u007f]/u.test(value);
}

export function createOpenWaOutboundAdapter(options: OpenWaOutboundAdapterOptions) {
  const baseUrl = normalizeBaseUrl(options.baseUrl);
  const apiKey = options.apiKey.trim();
  if (!apiKey) throw new Error("OpenWA outbound adapter requires a server-side API key.");

  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = Math.min(Math.max(options.timeoutMs ?? 10_000, 1_000), 30_000);

  return {
    async send(request: OpenWaWhatsAppDeliveryRequest): Promise<ProviderDeliveryResult> {
      const chatId = normalizeChatId(request.chatId);
      if (!validSessionId(request.sessionId)
        || !chatId
        || typeof request.body !== "string"
        || request.body.trim().length < 1
        || request.body.length > 4096) {
        return { kind: "permanent", errorCode: "openwa_invalid_request" };
      }

      let signal: AbortSignal;
      try {
        signal = AbortSignal.timeout(timeoutMs);
      } catch {
        return { kind: "retryable", errorCode: "openwa_request_setup_failed" };
      }

      let pendingResponse: Promise<Response>;
      try {
        pendingResponse = fetchImpl(
          `${baseUrl}/api/sessions/${encodeURIComponent(request.sessionId)}/messages/send-text`,
          {
            method: "POST",
            redirect: "error",
            headers: { "X-API-Key": apiKey, "content-type": "application/json" },
            body: JSON.stringify({ chatId, text: request.body }),
            signal,
          },
        );
      } catch {
        // Native fetch throws synchronously only while validating the request,
        // before it has dispatched anything to the provider.
        return { kind: "retryable", errorCode: "openwa_request_setup_failed" };
      }

      let response: Response;
      try {
        response = await pendingResponse;
      } catch {
        return { kind: "ambiguous", errorCode: "openwa_delivery_unknown" };
      }

      if (response.status === 409) return { kind: "retryable", errorCode: "openwa_session_not_ready" };
      if (response.status === 429) return { kind: "retryable", errorCode: "openwa_rate_limited" };
      if (response.status === 401 || response.status === 403) return { kind: "permanent", errorCode: "openwa_auth_denied" };
      if (response.status >= 500 || (response.status >= 300 && response.status < 400)) {
        return { kind: "ambiguous", errorCode: "openwa_delivery_unknown" };
      }
      if (!response.ok) return { kind: "permanent", errorCode: "openwa_rejected" };

      let payload: OpenWaSendResponse;
      try {
        payload = await response.json() as OpenWaSendResponse;
      } catch {
        return { kind: "ambiguous", errorCode: "openwa_delivery_unknown" };
      }

      return validMessageId(payload.messageId)
        ? { kind: "delivered", providerMessageId: payload.messageId }
        : { kind: "ambiguous", errorCode: "openwa_delivery_unknown" };
    },
  };
}
