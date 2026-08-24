import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

const source = readFileSync(resolve(process.cwd(), "supabase/functions/outbox-dispatch/index.ts"), "utf8");

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
    expect(source).toMatch(/aiOutcome === \"failed\"\) \{\s*failed \+= 1;\s*aiFailed \+= 1;\s*\}/u);
    expect(source).toMatch(/if \(failureState === \"retry_wait\"\) retried \+= 1;\s*else failed \+= 1;/u);
    expect(source).toMatch(/failed,\s*needsReview,/u);
    expect(source).not.toContain("failed: aiFailed");
  });
});