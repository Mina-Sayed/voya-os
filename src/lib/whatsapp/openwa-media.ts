const MAX_OPENWA_MEDIA_BYTES = 10 * 1024 * 1024;

export type SupportedWhatsappImageMime = "image/jpeg" | "image/png" | "image/webp";

export type OpenWaMediaRequest = Readonly<{
  sessionId: string;
  chatId: string;
  messageId: string;
  mimeTypeHint?: SupportedWhatsappImageMime | null;
}>;

export type OpenWaWhatsappMedia = Readonly<{
  messageId: string;
  mimeType: SupportedWhatsappImageMime;
  sizeBytes: number;
  bytes: Uint8Array;
}>;

type OpenWaMediaAdapterOptions = Readonly<{
  baseUrl: string;
  apiKey: string;
  maxBytes: number;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}>;

export class OpenWaWhatsAppMediaError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "OpenWaWhatsAppMediaError";
  }
}

function supportedMimeType(value: unknown): SupportedWhatsappImageMime | null {
  const mimeType = typeof value === "string" ? value.split(";", 1)[0]?.trim().toLowerCase() : null;
  return mimeType === "image/jpeg" || mimeType === "image/png" || mimeType === "image/webp" ? mimeType : null;
}

function canonicalSegment(value: unknown, maximum: number): value is string {
  return typeof value === "string"
    && value.length > 0
    && value.length <= maximum
    && value === value.trim()
    && !/[\u0000-\u001f\u007f]/u.test(value);
}

function validDirectChatId(value: string): boolean {
  return /^[A-Za-z0-9._:-]{1,250}@(c\.us|lid)$/u.test(value);
}

function isLiteralLoopbackHost(hostname: string): boolean {
  return hostname === "127.0.0.1" || hostname === "[::1]";
}

function normalizeBaseUrl(value: string): string {
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    throw new Error("OpenWA media adapter requires a valid root URL.");
  }
  if ((url.protocol !== "https:" && url.protocol !== "http:")
    || (url.protocol === "http:" && !isLiteralLoopbackHost(url.hostname))
    || url.pathname !== "/" || url.search || url.hash || url.username || url.password) {
    if (url.protocol === "http:" && !isLiteralLoopbackHost(url.hostname)) {
      throw new Error("HTTPS is required for OpenWA media outside loopback.");
    }
    throw new Error("OpenWA media adapter requires a valid root URL.");
  }
  return url.toString().replace(/\/$/u, "");
}

function contentLength(response: Response): number | null {
  const value = response.headers.get("content-length");
  if (!value) return null;
  const length = Number(value);
  return Number.isSafeInteger(length) && length >= 0 ? length : null;
}

function isAbortError(error: unknown): boolean {
  return typeof error === "object" && error !== null && "name" in error
    && (error.name === "AbortError" || error.name === "TimeoutError");
}

async function readBoundedBytes(response: Response, maxBytes: number): Promise<Uint8Array> {
  const declaredLength = contentLength(response);
  if (declaredLength !== null && declaredLength > maxBytes) throw new OpenWaWhatsAppMediaError("whatsapp_media_too_large");
  if (!response.body) throw new OpenWaWhatsAppMediaError("whatsapp_media_invalid_response");

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel().catch(() => undefined);
        throw new OpenWaWhatsAppMediaError("whatsapp_media_too_large");
      }
      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof OpenWaWhatsAppMediaError) throw error;
    if (isAbortError(error)) throw new OpenWaWhatsAppMediaError("whatsapp_media_timeout");
    throw new OpenWaWhatsAppMediaError("whatsapp_media_invalid_response");
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

function hasExpectedSignature(mimeType: SupportedWhatsappImageMime, bytes: Uint8Array): boolean {
  if (mimeType === "image/jpeg") return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (mimeType === "image/png") return bytes.length >= 8
    && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47
    && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a;
  return bytes.length >= 12
    && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46
    && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50;
}

export function createOpenWaMediaAdapter(options: OpenWaMediaAdapterOptions) {
  const baseUrl = normalizeBaseUrl(options.baseUrl);
  const apiKey = options.apiKey.trim();
  if (!apiKey) throw new Error("OpenWA media adapter requires a server-side API key.");
  if (!Number.isSafeInteger(options.maxBytes) || options.maxBytes < 1 || options.maxBytes > MAX_OPENWA_MEDIA_BYTES) {
    throw new Error("OpenWA media adapter byte limit must be between 1 byte and 10 MiB.");
  }

  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = Math.min(Math.max(options.timeoutMs ?? 10_000, 1), 30_000);

  return {
    async download(request: OpenWaMediaRequest): Promise<OpenWaWhatsappMedia> {
      if (!canonicalSegment(request.sessionId, 256)
        || !canonicalSegment(request.chatId, 256)
        || !validDirectChatId(request.chatId)
        || !canonicalSegment(request.messageId, 320)) {
        throw new OpenWaWhatsAppMediaError("whatsapp_media_invalid_request");
      }
      const mimeTypeHint = request.mimeTypeHint ?? null;
      if (mimeTypeHint !== null && !supportedMimeType(mimeTypeHint)) {
        throw new OpenWaWhatsAppMediaError("whatsapp_media_unsupported_type");
      }

      const url = `${baseUrl}/api/sessions/${encodeURIComponent(request.sessionId)}`
        + `/messages/${encodeURIComponent(request.chatId)}/${encodeURIComponent(request.messageId)}/media`;
      let response: Response;
      try {
        response = await fetchImpl(url, {
          method: "GET",
          headers: { "X-API-Key": apiKey },
          redirect: "error",
          signal: AbortSignal.timeout(timeoutMs),
        });
      } catch (error) {
        if (isAbortError(error)) throw new OpenWaWhatsAppMediaError("whatsapp_media_timeout");
        throw new OpenWaWhatsAppMediaError("whatsapp_media_provider_failure");
      }

      if (response.status === 404) throw new OpenWaWhatsAppMediaError("whatsapp_media_not_found");
      if (response.status === 401 || response.status === 403) throw new OpenWaWhatsAppMediaError("whatsapp_media_unauthorized");
      if (!response.ok) throw new OpenWaWhatsAppMediaError("whatsapp_media_provider_failure");

      const mimeType = supportedMimeType(response.headers.get("content-type"));
      if (!mimeType) throw new OpenWaWhatsAppMediaError("whatsapp_media_unsupported_type");
      if (mimeTypeHint && mimeTypeHint !== mimeType) throw new OpenWaWhatsAppMediaError("whatsapp_media_mime_mismatch");
      const bytes = await readBoundedBytes(response, options.maxBytes);
      if (!hasExpectedSignature(mimeType, bytes)) throw new OpenWaWhatsAppMediaError("whatsapp_media_signature_mismatch");

      return { messageId: request.messageId, mimeType, sizeBytes: bytes.byteLength, bytes };
    },
  };
}
