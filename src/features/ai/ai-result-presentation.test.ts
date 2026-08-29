import { expect, test } from "vitest";
import { parseAiResult } from "./ai-result-presentation";

test("parses a complete Gemini proposal into readable sections", () => {
  expect(parseAiResult(JSON.stringify({
    summary: "ملخص واضح",
    suggestions: ["اقتراح أول", "اقتراح ثان"],
    risks: ["مخاطرة واحدة"],
  }))).toEqual({
    kind: "structured",
    partial: false,
    summary: "ملخص واضح",
    suggestions: ["اقتراح أول", "اقتراح ثان"],
    risks: ["مخاطرة واحدة"],
    raw: expect.any(String),
  });
});

test("extracts readable sections from a truncated JSON response", () => {
  const result = parseAiResult('{"summary":"ملخص","suggestions":["اقتراح مكتمل","اقتراح ثانٍ"');

  expect(result).toMatchObject({
    kind: "structured",
    partial: true,
    summary: "ملخص",
    suggestions: ["اقتراح مكتمل", "اقتراح ثانٍ"],
  });
});
