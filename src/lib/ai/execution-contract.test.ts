import { expect, test } from "vitest";
import { buildAiGenerationRequest, classifyGeminiFailure, normalizeAiResult } from "./execution-contract";

test("builds a proposal-only prompt with the selected data class", () => {
  const request = buildAiGenerationRequest({ agentKind: "sales", purpose: "لخص طلب المتابعة", dataClass: "synthetic" });
  expect(request.dataClass).toBe("synthetic");
  expect(request.systemInstruction).toContain("لا تقل إن حجزاً أو رسالة أو عملية مالية نُفذت");
  expect(request.userPrompt).toContain("لخص طلب المتابعة");
});

test("only provider request failures are retried", () => {
  expect(classifyGeminiFailure({ code: "request_failed" })).toEqual({ kind: "retryable", errorCode: "ai_provider_request_failed" });
  expect(classifyGeminiFailure({ code: "missing_api_key" })).toEqual({ kind: "permanent", errorCode: "ai_provider_not_configured" });
  expect(classifyGeminiFailure(new Error("unknown"))).toEqual({ kind: "permanent", errorCode: "ai_provider_unknown" });
});

test("bounds and redacts control characters from stored AI output", () => {
  const result = normalizeAiResult({ provider: "fake", model: "preview", text: `ok\u0000${"x".repeat(20_000)}` });
  expect(result.output.startsWith("ok")).toBe(true);
  expect(result.output.length).toBe(12_000);
  expect(result.output).not.toContain("\u0000");
});
