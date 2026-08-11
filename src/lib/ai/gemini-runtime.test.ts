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

  test("requires an API key for approved production calls", async () => {
    const provider = createGeminiProvider({ environment: { NODE_ENV: "production", GEMINI_ENABLED: "true", GEMINI_CUSTOMER_DATA_APPROVED: "true" } });
    await expect(provider.generate({ task: "extraction", systemInstruction: "safe", userPrompt: "customer", dataClass: "customer_redacted" })).rejects.toMatchObject({ code: "missing_api_key" });
  });
});
