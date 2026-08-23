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
});
