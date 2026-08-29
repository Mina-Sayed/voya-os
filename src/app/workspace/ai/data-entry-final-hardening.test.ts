import { existsSync, readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const read = (path: string) => readFileSync(path, "utf8");
const hardeningMigration = "supabase/migrations/20260824040000_finalize_ai_data_entry_recovery.sql";
const lockOrderMigration = "supabase/migrations/20260824041000_align_ai_data_entry_lock_order.sql";

describe("AI data-entry final hardening contract", () => {
  test("persists incremental confirmation progress and preserves current IDs on heartbeat failure", () => {
    const source = read("src/app/workspace/ai/data-entry-actions.ts");
    expect(source).toContain('persist_ai_data_entry_confirmation_progress_v1');
    expect(source).toContain('resultIds(mergeDataEntryApplicationResults(priorTerminal, current))');
  });

  test("preserves bounded digit-leading SQLSTATE codes for image failures", () => {
    const source = read("src/app/workspace/ai/data-entry-actions.ts");
    expect(source).toContain('/^[a-z0-9][a-z0-9_.-]{0,119}$/u.test(error.message)');
  });

  test("stale confirmation reclaim is immutable and active confirmation can outlive the original draft expiry", () => {
    expect(existsSync(hardeningMigration)).toBe(true);
    if (!existsSync(hardeningMigration)) return;
    const migration = read(hardeningMigration);
    expect(migration).toContain("confirmation payload changed during recovery");
    expect(migration).toContain("CREATE OR REPLACE FUNCTION public.heartbeat_ai_data_entry_confirmation_v3");
    const heartbeat = migration.split("CREATE OR REPLACE FUNCTION public.heartbeat_ai_data_entry_confirmation_v3", 2)[1]
      .split("CREATE OR REPLACE FUNCTION", 2)[0];
    expect(heartbeat).not.toContain("draft.expires_at >");
  });

  test("trusted mapping takes the draft lock before the input lock", () => {
    expect(existsSync(lockOrderMigration)).toBe(true);
    if (!existsSync(lockOrderMigration)) return;
    const mapping = read(lockOrderMigration).split("CREATE OR REPLACE FUNCTION public.mark_ai_data_entry_input_mapped_v2", 2)[1]
      .split("REVOKE ALL ON FUNCTION", 2)[0];
    const draftLock = mapping.indexOf("FROM public.ai_data_entry_drafts AS draft");
    const inputLock = mapping.indexOf("SELECT input.* INTO v_input");
    expect(draftLock).toBeGreaterThanOrEqual(0);
    expect(inputLock).toBeGreaterThan(draftLock);
  });

  test("rejection only permits ready-for-review drafts plus idempotent rejected replay", () => {
    expect(existsSync(hardeningMigration)).toBe(true);
    if (!existsSync(hardeningMigration)) return;
    const migration = read(hardeningMigration);
    const rejection = migration.split("CREATE OR REPLACE FUNCTION public.reject_ai_data_entry_draft_v1", 2)[1]
      .split("CREATE OR REPLACE FUNCTION", 2)[0];
    expect(rejection).toContain("v_draft.status = 'rejected'");
    expect(rejection).toContain("v_draft.status <> 'ready_for_review'");
  });

  test("data-entry needs-review events participate in AI recovery observability", () => {
    expect(existsSync(hardeningMigration)).toBe(true);
    if (!existsSync(hardeningMigration)) return;
    const migration = read(hardeningMigration);
    expect(migration).toContain("ai.data_entry.requested");
    expect(migration).toContain("needs_review");
    expect(migration).toContain("get_system_health_v1");
  });

  test("upload retries keep a stable file key and refresh server draft state after success", () => {
    const source = read("src/features/ai/data-entry-intake.tsx");
    expect(source).toContain("useRouter");
    expect(source).toContain("uploadKeysRef");
    expect(source).toContain("router.refresh()");
  });

  test("SSR timestamp formatting uses a fixed timezone", () => {
    const source = read("src/features/ai/agent-center-page.tsx");
    expect(source).toContain('timeZone: "UTC"');
  });

  test("applied properties cannot steal new image bindings while failed original mappings stay recoverable", () => {
    const source = read("src/features/ai/data-entry-review.tsx");
    expect(source).toContain("const wasOriginallySelected = review.payload.properties[index]?.imageInputIds.includes(input.id) ?? false");
    expect(source).toContain("const recoverableAppliedImage = applied && (wasOriginallySelected || Boolean(imageResult))");
    expect(source).toContain('const imageDisabled = !canWriteProperties || input.status === "archived" || recoveryLocked || !included || imageApplied');
  });

  test("confirmed recovery renders the claimed payload as immutable", () => {
    const source = read("src/features/ai/data-entry-review.tsx");
    expect(source).toContain('const recoveryLocked = review.status === "confirmed"');
    expect(source).toContain("!canWriteProperties || recoveryLocked || applied || !included");
  });
});
