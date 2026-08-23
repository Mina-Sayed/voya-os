import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const workerSource = readFileSync("supabase/functions/outbox-dispatch/index.ts", "utf8");

describe("AI data-entry worker recovery contract", () => {
  test("terminalizes data-entry run and draft atomically before private-input cleanup", () => {
    const finalizer = workerSource.indexOf('rpc("finalize_ai_data_entry_failure_v1"');
    const cleanup = workerSource.indexOf("cleanupDataEntryInputs(", finalizer + 1);

    expect(finalizer).toBeGreaterThanOrEqual(0);
    expect(cleanup).toBeGreaterThan(finalizer);
  });

  test("routes cleanup failure after terminalization to needs_review instead of provider retry", () => {
    expect(workerSource).toContain('rpc("finalize_ai_data_entry_failure_v1"');
    expect(workerSource).toMatch(/cleanupDataEntryInputs[\s\S]{0,1800}mark_outbox_needs_review/u);
  });
});
