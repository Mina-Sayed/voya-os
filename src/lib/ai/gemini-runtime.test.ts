import { describe, expect, test, vi } from "vitest";
import { createGeminiProvider, GeminiProviderError, readGeminiRuntimeConfig } from "./gemini-runtime";

describe("Gemini runtime policy", () => {
  test("forces synthetic fake responses in preview and disables external channels by default", () => {
    const config = readGeminiRuntimeConfig({
      NODE_ENV: "test",
      VERCEL_ENV: "preview",
      GEMINI_ENABLED: "true",
      WHATSAPP_OUTBOUND_ENABLED: "true",
      WHATSAPP_AI_AUTO_REPLIES: "true",
      HUMAN_HANDOFF_APPROVED: "false",
    });
    expect(config.syntheticOnly).toBe(true);
    expect(config.outboundEnabled).toBe(false);
    expect(config.autoRepliesEnabled).toBe(false);
    expect(config.mainModel).toBe("gemini-3.5-flash");
    expect(config.extractionModel).toBe("gemini-3.5-flash-lite");
  });

  test("never calls the network for an enabled preview run", async () => {
    const fetchImpl = vi.fn();
    const provider = createGeminiProvider({ environment: { NODE_ENV: "test", VERCEL_ENV: "preview", GEMINI_ENABLED: "true" }, fetchImpl });
    await expect(provider.generate({ task: "main", systemInstruction: "safe", userPrompt: "synthetic", dataClass: "synthetic" })).resolves.toMatchObject({ provider: "fake" });
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  test("returns a schema-valid synthetic WhatsApp response without a network call", async () => {
    const fetchImpl = vi.fn();
    const provider = createGeminiProvider({ environment: { NODE_ENV: "test", VERCEL_ENV: "preview", GEMINI_ENABLED: "true" }, fetchImpl });
    const result = await provider.generate({ task: "main", systemInstruction: "أنت VOYA WhatsApp Agent", userPrompt: "synthetic", dataClass: "synthetic" });
    const payload = JSON.parse(result.text) as Record<string, unknown>;

    expect(payload).toMatchObject({
      conversationType: "unknown",
      facts: { language: "ar", owner: null, property: null, lead: null },
      missingFields: ["conversationType"],
      recommendedAction: "continue",
      confidence: "low",
    });
    expect(typeof payload.reply).toBe("string");
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  test("fails closed before sending customer data without explicit approval", async () => {
    const provider = createGeminiProvider({ environment: { NODE_ENV: "production", GEMINI_ENABLED: "true", GEMINI_API_KEY: "do-not-print" } });
    await expect(provider.generate({ task: "main", systemInstruction: "safe", userPrompt: "customer", dataClass: "customer_redacted" })).rejects.toMatchObject({ code: "customer_data_not_approved" });
  });

  test("maps provider failures without leaking the API key", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response("bad", { status: 500 }));
    const provider = createGeminiProvider({ environment: { NODE_ENV: "production", GEMINI_ENABLED: "true", GEMINI_API_KEY: "secret-key" }, fetchImpl });
    const error = await provider.generate({ task: "main", systemInstruction: "safe", userPrompt: "synthetic", dataClass: "synthetic" }).catch((value) => value as GeminiProviderError);
    expect(error).toMatchObject({ code: "request_failed" });
    expect(JSON.stringify(error)).not.toContain("secret-key");
  });

  test("authenticates Gemini with x-goog-api-key without placing the secret in the URL", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: "{}" }] } }] }), { status: 200 }));
    const provider = createGeminiProvider({ environment: { NODE_ENV: "production", GEMINI_ENABLED: "true", GEMINI_API_KEY: "secret-key" }, fetchImpl });

    await provider.generate({ task: "main", systemInstruction: "safe", userPrompt: "synthetic", dataClass: "synthetic" });

    const [url, init] = fetchImpl.mock.calls[0] ?? [];
    expect(String(url)).not.toContain("secret-key");
    expect(String(url)).not.toContain("?key=");
    expect(init?.headers).toMatchObject({ "content-type": "application/json", "x-goog-api-key": "secret-key" });
  });

  test("allocates enough output budget for a complete structured proposal", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: '{"summary":"ok"}' }] } }] }), { status: 200 }));
    const provider = createGeminiProvider({ environment: { NODE_ENV: "production", GEMINI_ENABLED: "true", GEMINI_CUSTOMER_DATA_APPROVED: "true", GEMINI_API_KEY: "secret-key" }, fetchImpl });

    await provider.generate({ task: "main", systemInstruction: "safe", userPrompt: "customer", dataClass: "customer_redacted" });

    const request = fetchImpl.mock.calls[0]?.[1];
    const body = JSON.parse(String(request?.body)) as { generationConfig?: { maxOutputTokens?: number } };
    expect(body.generationConfig?.maxOutputTokens).toBe(1600);
  });

  test("requires an API key for approved production calls", async () => {
    const provider = createGeminiProvider({ environment: { NODE_ENV: "production", GEMINI_ENABLED: "true", GEMINI_CUSTOMER_DATA_APPROVED: "true" } });
    await expect(provider.generate({ task: "extraction", systemInstruction: "safe", userPrompt: "customer", dataClass: "customer_redacted" })).rejects.toMatchObject({ code: "missing_api_key" });
  });

  test("sends bounded image parts as inline data for extraction", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: "{}" }] } }] }), { status: 200 }));
    const provider = createGeminiProvider({ environment: { NODE_ENV: "production", GEMINI_ENABLED: "true", GEMINI_CUSTOMER_DATA_APPROVED: "true", GEMINI_API_KEY: "secret-key" }, fetchImpl });

    await provider.generate({
      task: "extraction",
      systemInstruction: "safe",
      userPrompt: "customer",
      dataClass: "customer_redacted",
      imageParts: [{ mimeType: "image/png", data: "encoded-image" }],
    });

    const request = fetchImpl.mock.calls[0]?.[1];
    const body = JSON.parse(String(request?.body)) as { contents?: { parts?: { inlineData?: { mimeType?: string; data?: string } }[] }[] };
    expect(body.contents?.[0]?.parts).toEqual(expect.arrayContaining([
      { text: "customer" },
      { inlineData: { mimeType: "image/png", data: "encoded-image" } },
    ]));
  });
});
