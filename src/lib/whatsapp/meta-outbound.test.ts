import { describe, expect, it, vi } from "vitest";
import { createMetaWhatsAppOutboundAdapter } from "./meta-outbound";

const request = {
  phoneNumberId: "phone-number-1",
  to: "+201000000000",
  body: "مرحبا",
  idempotencyKey: "event-1",
};

describe("Meta WhatsApp outbound adapter", () => {
  it("sends a reviewed text message through the configured Graph API version", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response(JSON.stringify({ messages: [{ id: "wamid-1" }] }), { status: 200 }));
    const adapter = createMetaWhatsAppOutboundAdapter({ accessToken: "meta-secret", graphApiVersion: "v21.0", fetchImpl });

    await expect(adapter.send(request)).resolves.toEqual({ kind: "delivered", providerMessageId: "wamid-1" });
    expect(fetchImpl).toHaveBeenCalledWith("https://graph.facebook.com/v21.0/phone-number-1/messages", expect.objectContaining({
      method: "POST",
      headers: { authorization: "Bearer meta-secret", "content-type": "application/json" },
      body: JSON.stringify({ messaging_product: "whatsapp", to: "+201000000000", type: "text", text: { body: "مرحبا" } }),
    }));
  });

  it("maps provider overload and timeout without claiming delivery", async () => {
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(new Response("busy", { status: 503 }))
      .mockRejectedValueOnce(Object.assign(new Error("timeout"), { name: "AbortError" }));
    const adapter = createMetaWhatsAppOutboundAdapter({ accessToken: "meta-secret", graphApiVersion: "v21.0", fetchImpl });

    await expect(adapter.send(request)).resolves.toEqual({ kind: "retryable", errorCode: "whatsapp_provider_error" });
    await expect(adapter.send(request)).resolves.toEqual({ kind: "ambiguous", errorCode: "whatsapp_provider_timeout" });
  });

  it("requires a server-side access token and explicit Graph API version", () => {
    expect(() => createMetaWhatsAppOutboundAdapter({ accessToken: "", graphApiVersion: "v21.0" })).toThrow("WhatsApp");
    expect(() => createMetaWhatsAppOutboundAdapter({ accessToken: "meta-secret", graphApiVersion: "" })).toThrow("WhatsApp");
  });
});
