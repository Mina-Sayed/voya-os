import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

type SupportedMime = "image/jpeg" | "image/png" | "image/webp";
type DownloadResult = Readonly<{
  messageId: string;
  mimeType: SupportedMime;
  sizeBytes: number;
  bytes: Uint8Array;
}>;
type Adapter = Readonly<{
  download(input: Readonly<{
    sessionId: string;
    chatId: string;
    messageId: string;
    mimeTypeHint?: SupportedMime | null;
  }>): Promise<DownloadResult>;
}>;
type AdapterFactory = (options: Readonly<{
  baseUrl: string;
  apiKey: string;
  maxBytes: number;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}>) => Adapter;

const adapterModules = import.meta.glob("./openwa-media.ts");
let createOpenWaMediaAdapter: AdapterFactory | undefined;

beforeAll(async () => {
  const loadModule = Object.values(adapterModules)[0];
  const adapterExports = loadModule ? await loadModule() as Record<string, unknown> : null;
  if (adapterExports && "createOpenWaMediaAdapter" in adapterExports) {
    createOpenWaMediaAdapter = adapterExports.createOpenWaMediaAdapter as AdapterFactory;
  }
});

afterAll(() => vi.restoreAllMocks());

function adapter(options: Parameters<AdapterFactory>[0]): Adapter {
  expect(createOpenWaMediaAdapter).toBeTypeOf("function");
  return createOpenWaMediaAdapter!(options);
}

const images: ReadonlyArray<Readonly<{ mimeType: SupportedMime; bytes: Uint8Array }>> = [
  { mimeType: "image/jpeg", bytes: new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00]) },
  { mimeType: "image/png", bytes: new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) },
  { mimeType: "image/webp", bytes: new Uint8Array([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50]) },
];

function copyBytesToArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}

describe("OpenWA WhatsApp media adapter", () => {
  it("rejects cleartext HTTP outside literal loopback development hosts", () => {
    expect(() => adapter({ baseUrl: "http://openwa.example.test", apiKey: "server-only-key", maxBytes: 1024 }))
      .toThrow("HTTPS is required for OpenWA media outside loopback.");
    expect(() => adapter({ baseUrl: "http://localhost:55322", apiKey: "server-only-key", maxBytes: 1024 }))
      .toThrow("HTTPS is required for OpenWA media outside loopback.");
    expect(() => adapter({ baseUrl: "http://127.0.0.1:55322", apiKey: "server-only-key", maxBytes: 1024 })).not.toThrow();
    expect(() => adapter({ baseUrl: "http://[::1]:55322", apiKey: "server-only-key", maxBytes: 1024 })).not.toThrow();
  });

  it.each(images)("downloads bounded $mimeType bytes from the authenticated message route", async ({ mimeType, bytes }) => {
    const key = "server-only-openwa-key";
    const fetchRequests: Array<Readonly<[RequestInfo | URL, RequestInit?]>> = [];
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      fetchRequests.push([input, init]);
      return new Response(copyBytesToArrayBuffer(bytes), {
        status: 200,
        headers: { "content-type": mimeType, "content-length": String(bytes.byteLength) },
      });
    });
    const fetchImpl = fetchMock as unknown as typeof fetch;
    const consoleSpies = [vi.spyOn(console, "log"), vi.spyOn(console, "info"), vi.spyOn(console, "warn"), vi.spyOn(console, "error")];
    const media = await adapter({ baseUrl: "https://openwa.example.test", apiKey: key, maxBytes: 1024, fetchImpl })
      .download({ sessionId: "session/primary", chatId: "201001234567@c.us", messageId: "wamid/one", mimeTypeHint: mimeType });

    expect(media).toEqual({ messageId: "wamid/one", mimeType, sizeBytes: bytes.byteLength, bytes });
    expect(fetchMock).toHaveBeenCalledWith(
      "https://openwa.example.test/api/sessions/session%2Fprimary/messages/201001234567%40c.us/wamid%2Fone/media",
      expect.objectContaining({ method: "GET", redirect: "error", headers: { "X-API-Key": key } }),
    );
    expect(fetchRequests[0]?.[0]).not.toContain(key);
    for (const spy of consoleSpies) expect(spy).not.toHaveBeenCalled();
  });

  it.each([
    { status: 404, code: "whatsapp_media_not_found" },
    { status: 401, code: "whatsapp_media_unauthorized" },
    { status: 403, code: "whatsapp_media_unauthorized" },
  ])("fails safely when OpenWA responds with HTTP $status", async ({ status, code }) => {
    const fetchImpl = vi.fn(async () => new Response("provider response body", { status })) as unknown as typeof fetch;
    const mediaAdapter = adapter({ baseUrl: "https://openwa.example.test", apiKey: "server-only-key", maxBytes: 1024, fetchImpl });

    await expect(mediaAdapter.download({ sessionId: "session", chatId: "201001234567@c.us", messageId: "message" }))
      .rejects.toMatchObject({ code });
  });

  it("maps an aborted provider request to a timeout without exposing response content", async () => {
    const fetchImpl = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), { once: true });
    })) as unknown as typeof fetch;
    const mediaAdapter = adapter({ baseUrl: "https://openwa.example.test", apiKey: "server-only-key", maxBytes: 1024, fetchImpl, timeoutMs: 5 });

    await expect(mediaAdapter.download({ sessionId: "session", chatId: "201001234567@c.us", messageId: "message" }))
      .rejects.toMatchObject({ code: "whatsapp_media_timeout" });
  });

  it("rejects non-image response MIME types", async () => {
    const fetchImpl = vi.fn(async () => new Response("not an image", {
      status: 200,
      headers: { "content-type": "application/pdf" },
    })) as unknown as typeof fetch;
    const mediaAdapter = adapter({ baseUrl: "https://openwa.example.test", apiKey: "server-only-key", maxBytes: 1024, fetchImpl });

    await expect(mediaAdapter.download({ sessionId: "session", chatId: "201001234567@c.us", messageId: "message" }))
      .rejects.toMatchObject({ code: "whatsapp_media_unsupported_type" });
  });

  it("rejects malformed and group chat IDs before making a provider request", async () => {
    const fetchImpl = vi.fn() as unknown as typeof fetch;
    const mediaAdapter = adapter({ baseUrl: "https://openwa.example.test", apiKey: "server-only-key", maxBytes: 1024, fetchImpl });

    await expect(mediaAdapter.download({ sessionId: "session", chatId: "not-a-jid", messageId: "message" }))
      .rejects.toMatchObject({ code: "whatsapp_media_invalid_request" });
    await expect(mediaAdapter.download({ sessionId: "session", chatId: "120363123456@g.us", messageId: "message" }))
      .rejects.toMatchObject({ code: "whatsapp_media_invalid_request" });
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("rejects a streamed body that exceeds the configured media cap", async () => {
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]));
        controller.enqueue(new Uint8Array([0x00]));
        controller.close();
      },
    });
    const fetchImpl = vi.fn(async () => new Response(body, {
      status: 200,
      headers: { "content-type": "image/jpeg" },
    })) as unknown as typeof fetch;
    const mediaAdapter = adapter({ baseUrl: "https://openwa.example.test", apiKey: "server-only-key", maxBytes: 4, fetchImpl });

    await expect(mediaAdapter.download({ sessionId: "session", chatId: "201001234567@c.us", messageId: "message" }))
      .rejects.toMatchObject({ code: "whatsapp_media_too_large" });
  });

  it("rejects image bytes whose signature disagrees with the declared MIME", async () => {
    const png = images[1]!.bytes;
    const fetchImpl = vi.fn(async () => new Response(copyBytesToArrayBuffer(png), {
      status: 200,
      headers: { "content-type": "image/jpeg" },
    })) as unknown as typeof fetch;
    const mediaAdapter = adapter({ baseUrl: "https://openwa.example.test", apiKey: "server-only-key", maxBytes: 1024, fetchImpl });

    await expect(mediaAdapter.download({ sessionId: "session", chatId: "201001234567@c.us", messageId: "message", mimeTypeHint: "image/jpeg" }))
      .rejects.toMatchObject({ code: "whatsapp_media_signature_mismatch" });
  });
});
