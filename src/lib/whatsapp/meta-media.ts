const MAX_MEDIA_BYTES = 10 * 1024 * 1024;

type SupportedImageMimeType = "image/jpeg" | "image/png" | "image/webp";

type MetaWhatsAppMediaAdapterOptions = Readonly<{
  accessToken: string;
  graphApiVersion: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}>;

type MetaWhatsAppMediaRequest = Readonly<{
  providerMediaId: string;
  mimeTypeHint: SupportedImageMimeType | null;
}>;

export type MetaWhatsAppMedia = Readonly<{
  providerMediaId: string;
  mimeType: SupportedImageMimeType;
  sizeBytes: number;
  bytes: Uint8Array;
}>;

export class MetaWhatsAppMediaError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "MetaWhatsAppMediaError";
  }
}

type UnknownRecord = Readonly<Record<string, unknown>>;

type MetaMediaMetadata = Readonly<{
  url: string;
  mimeType: SupportedImageMimeType;
  fileSize: number | null;
}>;

function record(value: unknown): UnknownRecord | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as UnknownRecord : null;
}

function supportedMimeType(value: unknown): SupportedImageMimeType | null {
  const mimeType = typeof value === "string" ? value.split(";", 1)[0]?.trim().toLowerCase() : null;
  return mimeType === "image/jpeg" || mimeType === "image/png" || mimeType === "image/webp" ? mimeType : null;
}

function boundedProviderMediaId(value: string): string | null {
  const mediaId = value.trim();
  return mediaId.length > 0 && mediaId.length <= 320 ? mediaId : null;
}

function isMetaDownloadUrl(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 2_048) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && (url.hostname === "graph.facebook.com" || url.hostname === "lookaside.fbsbx.com");
  } catch {
    return false;
  }
}

function metadata(value: unknown): MetaMediaMetadata {
  const payload = record(value);
  if (!payload || !isMetaDownloadUrl(payload.url)) throw new MetaWhatsAppMediaError("meta_media_invalid_response");
  const mimeType = supportedMimeType(payload.mime_type);
  if (!mimeType) throw new MetaWhatsAppMediaError("meta_media_unsupported_type");
  const fileSize = payload.file_size;
  if (fileSize !== undefined && (typeof fileSize !== "number" || !Number.isSafeInteger(fileSize) || fileSize < 0)) {
    throw new MetaWhatsAppMediaError("meta_media_invalid_response");
  }
  if (typeof fileSize === "number" && fileSize > MAX_MEDIA_BYTES) throw new MetaWhatsAppMediaError("meta_media_too_large");
  return { url: payload.url, mimeType, fileSize: typeof fileSize === "number" ? fileSize : null };
}

function contentLength(response: Response): number | null {
  const value = response.headers.get("content-length");
  if (!value) return null;
  const length = Number(value);
  return Number.isSafeInteger(length) && length >= 0 ? length : null;
}

async function readBoundedBytes(response: Response): Promise<Uint8Array> {
  const declaredLength = contentLength(response);
  if (declaredLength !== null && declaredLength > MAX_MEDIA_BYTES) throw new MetaWhatsAppMediaError("meta_media_too_large");
  if (!response.body) throw new MetaWhatsAppMediaError("meta_media_invalid_response");

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_MEDIA_BYTES) {
        await reader.cancel();
        throw new MetaWhatsAppMediaError("meta_media_too_large");
      }
      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof MetaWhatsAppMediaError) throw error;
    throw new MetaWhatsAppMediaError("meta_media_invalid_response");
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

function hasExpectedSignature(mimeType: SupportedImageMimeType, bytes: Uint8Array): boolean {
  if (mimeType === "image/jpeg") return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (mimeType === "image/png") return bytes.length >= 8
    && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47
    && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a;
  return bytes.length >= 12
    && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46
    && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50;
}

async function fetchWithTimeout(fetchImpl: typeof fetch, input: RequestInfo | URL, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetchImpl(input, { ...init, signal: controller.signal });
  } catch (error) {
    if (error instanceof Error && error.name === "AbortError") throw new MetaWhatsAppMediaError("meta_media_timeout");
    throw new MetaWhatsAppMediaError("meta_media_provider_failure");
  } finally {
    clearTimeout(timer);
  }
}

export function createMetaWhatsAppMediaAdapter(options: MetaWhatsAppMediaAdapterOptions) {
  const accessToken = options.accessToken.trim();
  const graphApiVersion = options.graphApiVersion.trim();
  if (!accessToken || !/^v[0-9]+(?:\.[0-9]+)?$/u.test(graphApiVersion)) {
    throw new Error("WhatsApp media adapter requires a server-side access token and Graph API version.");
  }
  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = Math.min(Math.max(options.timeoutMs ?? 10_000, 1_000), 30_000);

  return {
    async download(request: MetaWhatsAppMediaRequest): Promise<MetaWhatsAppMedia> {
      const providerMediaId = boundedProviderMediaId(request.providerMediaId);
      if (!providerMediaId) throw new MetaWhatsAppMediaError("meta_media_invalid_request");
      const headers = { authorization: `Bearer ${accessToken}` };
      const metadataResponse = await fetchWithTimeout(
        fetchImpl,
        `https://graph.facebook.com/${graphApiVersion}/${encodeURIComponent(providerMediaId)}`,
        { method: "GET", headers, redirect: "error" },
        timeoutMs,
      );
      if (!metadataResponse.ok) throw new MetaWhatsAppMediaError("meta_media_provider_failure");

      let metadataPayload: unknown;
      try {
        metadataPayload = await metadataResponse.json();
      } catch {
        throw new MetaWhatsAppMediaError("meta_media_invalid_response");
      }
      const resolvedMetadata = metadata(metadataPayload);
      if (request.mimeTypeHint && request.mimeTypeHint !== resolvedMetadata.mimeType) {
        throw new MetaWhatsAppMediaError("meta_media_mime_mismatch");
      }

      const mediaResponse = await fetchWithTimeout(fetchImpl, resolvedMetadata.url, { method: "GET", headers, redirect: "error" }, timeoutMs);
      if (!mediaResponse.ok) throw new MetaWhatsAppMediaError("meta_media_provider_failure");
      if (supportedMimeType(mediaResponse.headers.get("content-type")) !== resolvedMetadata.mimeType) {
        throw new MetaWhatsAppMediaError("meta_media_mime_mismatch");
      }
      const bytes = await readBoundedBytes(mediaResponse);
      if (!hasExpectedSignature(resolvedMetadata.mimeType, bytes)) throw new MetaWhatsAppMediaError("meta_media_signature_mismatch");
      return { providerMediaId, mimeType: resolvedMetadata.mimeType, sizeBytes: bytes.byteLength, bytes };
    },
  };
}
