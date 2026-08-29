import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

const source = readFileSync(resolve(process.cwd(), "supabase/functions/outbox-dispatch/index.ts"), "utf8");
const compactSource = source.replace(/\s+/gu, " ");

describe("outbox edge worker static safety contract", () => {
  test("keeps semantic type checking enabled", () => {
    expect(source).not.toContain("@ts-nocheck");
    expect(source).not.toContain("/* eslint-disable */");
  });

  test("requires positive RPC ownership results before recording delivery completion", () => {
    expect(source).toContain("markedSent !== true");
    expect(source).toContain("data === true");
    expect(source).toContain("failureState !== \"retry_wait\"");
    expect(source).toContain("completeLeasedEvent");
  });

  test("tracks generic dead letters separately from the AI failure response metric", () => {
    expect(source).toContain("let failed = 0;");
    expect(compactSource).toContain('else if (aiOutcome === "failed") { failed += 1; aiFailed += 1; }');
    expect(compactSource).toContain('if (failureState === "retry_wait") retried += 1; else failed += 1;');
    expect(compactSource).toContain("p_failed_count: counts.failed");
    expect(compactSource).toContain("failed, needsReview");
    expect(source).not.toMatch(/(?:^|[{,]\s*)failed\s*:\s*aiFailed(?:\s*[,}])/mu);
  });
});