import { describe, expect, it, vi } from "vitest";
import { createMetaWhatsAppMediaAdapter } from "./meta-media";

const jpegBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);

describe("Meta WhatsApp media adapter", () => {
  it("downloads an image only after Meta metadata and bytes agree on JPEG", async () => {
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        id: "media-1",
        url: "https://lookaside.fbsbx.com/whatsapp_business/attachments/media-1",
        mime_type: "image/jpeg",
        file_size: jpegBytes.byteLength,
      }), { status: 200, headers: { "content-type": "application/json" } }))
      .mockResolvedValueOnce(new Response(jpegBytes, {
        status: 200,
        headers: { "content-type": "image/jpeg", "content-length": String(jpegBytes.byteLength) },
      }));
    const adapter = createMetaWhatsAppMediaAdapter({ accessToken: "meta-secret", graphApiVersion: "v21.0", fetchImpl });

    await expect(adapter.download({ providerMediaId: "media-1", mimeTypeHint: "image/jpeg" })).resolves.toEqual({
      providerMediaId: "media-1",
      mimeType: "image/jpeg",
      sizeBytes: jpegBytes.byteLength,
      bytes: jpegBytes,
    });
    expect(fetchImpl).toHaveBeenNthCalledWith(1, "https://graph.facebook.com/v21.0/media-1", expect.objectContaining({
      headers: { authorization: "Bearer meta-secret" },
      method: "GET",
    }));
  });

  it("rejects unsupported metadata MIME types before downloading bytes", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      id: "media-1",
      url: "https://lookaside.fbsbx.com/whatsapp_business/attachments/media-1",
      mime_type: "image/gif",
      file_size: 10,
    }), { status: 200 }));
    const adapter = createMetaWhatsAppMediaAdapter({ accessToken: "meta-secret", graphApiVersion: "v21.0", fetchImpl });

    await expect(adapter.download({ providerMediaId: "media-1", mimeTypeHint: null })).rejects.toMatchObject({ code: "meta_media_unsupported_type" });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("rejects metadata that declares a payload above the 10 MiB ceiling", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      id: "media-1",
      url: "https://lookaside.fbsbx.com/whatsapp_business/attachments/media-1",
      mime_type: "image/jpeg",
      file_size: 10 * 1024 * 1024 + 1,
    }), { status: 200 }));
    const adapter = createMetaWhatsAppMediaAdapter({ accessToken: "meta-secret", graphApiVersion: "v21.0", fetchImpl });

    await expect(adapter.download({ providerMediaId: "media-1", mimeTypeHint: "image/jpeg" })).rejects.toMatchObject({ code: "meta_media_too_large" });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("rejects bytes that exceed the ceiling when their content length is absent", async () => {
    const oversizedBody = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(10 * 1024 * 1024));
        controller.enqueue(new Uint8Array([0]));
        controller.close();
      },
    });
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        id: "media-1",
        url: "https://lookaside.fbsbx.com/whatsapp_business/attachments/media-1",
        mime_type: "image/jpeg",
      }), { status: 200 }))
      .mockResolvedValueOnce(new Response(oversizedBody, { status: 200, headers: { "content-type": "image/jpeg" } }));
    const adapter = createMetaWhatsAppMediaAdapter({ accessToken: "meta-secret", graphApiVersion: "v21.0", fetchImpl });

    await expect(adapter.download({ providerMediaId: "media-1", mimeTypeHint: "image/jpeg" })).rejects.toMatchObject({ code: "meta_media_too_large" });
  });

  it("rejects MIME and image signature mismatches", async () => {
    const pngBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        id: "media-1",
        url: "https://lookaside.fbsbx.com/whatsapp_business/attachments/media-1",
        mime_type: "image/jpeg",
        file_size: pngBytes.byteLength,
      }), { status: 200 }))
      .mockResolvedValueOnce(new Response(pngBytes, { status: 200, headers: { "content-type": "image/jpeg" } }));
    const adapter = createMetaWhatsAppMediaAdapter({ accessToken: "meta-secret", graphApiVersion: "v21.0", fetchImpl });

    await expect(adapter.download({ providerMediaId: "media-1", mimeTypeHint: "image/jpeg" })).rejects.toMatchObject({ code: "meta_media_signature_mismatch" });
  });

  it("rejects a download content type that disagrees with Meta metadata", async () => {
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        id: "media-1",
        url: "https://lookaside.fbsbx.com/whatsapp_business/attachments/media-1",
        mime_type: "image/jpeg",
        file_size: jpegBytes.byteLength,
      }), { status: 200 }))
      .mockResolvedValueOnce(new Response(jpegBytes, { status: 200, headers: { "content-type": "image/png" } }));
    const adapter = createMetaWhatsAppMediaAdapter({ accessToken: "meta-secret", graphApiVersion: "v21.0", fetchImpl });

    await expect(adapter.download({ providerMediaId: "media-1", mimeTypeHint: "image/jpeg" })).rejects.toMatchObject({ code: "meta_media_mime_mismatch" });
  });

  it("maps a provider timeout to a safe failure code", async () => {
    const fetchImpl = vi.fn().mockRejectedValue(Object.assign(new Error("timeout"), { name: "AbortError" }));
    const adapter = createMetaWhatsAppMediaAdapter({ accessToken: "meta-secret", graphApiVersion: "v21.0", fetchImpl, timeoutMs: 1_000 });

    await expect(adapter.download({ providerMediaId: "media-1", mimeTypeHint: null })).rejects.toMatchObject({ code: "meta_media_timeout" });
  });
});
