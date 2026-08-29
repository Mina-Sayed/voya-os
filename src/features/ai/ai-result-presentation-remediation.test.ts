import { describe, expect, test } from "vitest";
import { parseAiResult } from "./ai-result-presentation";

describe("AI result presentation remediation", () => {
  test("does not consume later fields when recovering a closed suggestions array", () => {
    const result = parseAiResult('{"suggestions":["follow up"],"risks":["overlap"');

    expect(result).toMatchObject({
      partial: true,
      suggestions: ["follow up"],
      risks: ["overlap"],
    });
  });

  test("marks valid JSON with malformed structured fields as partial", () => {
    const result = parseAiResult(JSON.stringify({
      summary: "ok",
      suggestions: "follow up",
      risks: [],
    }));

    expect(result.kind).toBe("structured");
    expect(result.partial).toBe(true);
    expect(result.raw).toContain("follow up");
  });
});
