import { existsSync, readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const read = (path: string) => readFileSync(path, "utf8");
const route = read("src/app/api/workspace/ai/data-entry/inputs/route.ts");
const worker = read("supabase/functions/outbox-dispatch/index.ts");
const review = read("src/features/ai/data-entry-review.tsx");
const page = read("src/app/workspace/ai/page.tsx");
const actions = read("src/app/workspace/ai/data-entry-actions.ts");
const agentCenter = read("src/features/ai/agent-center-page.tsx");
const intake = read("src/features/ai/data-entry-intake.tsx");
const migrationPath = "supabase/migrations/20260827010000_harden_ai_data_entry_review_findings.sql";

describe("PR #12 AI data-entry review regressions", () => {
  test("cleans intake objects after a denied extracting transition only when terminalization succeeded", () => {
    const branch = worker.split("if (extractingError || extracting !== true)", 2)[1]?.split("  try {", 1)[0] ?? "";
    expect(branch).toContain("const terminalized = await failAiRunAndMarkNeedsReview");
    expect(branch).toMatch(/terminalized\s*&&\s*!extractingError[\s\S]*cleanupDataEntryInputs/u);
  });

  test("serializes deterministic upload ownership before metadata registration", () => {
    expect(route).toContain('error: "registration_pending"');
  });

  test("rejects image bodies whose magic bytes do not match their declared MIME type", () => {
    expect(route).toContain("matchesDeclaredImageType");
    expect(route).toContain("0x89");
    expect(route).toContain("RIFF");
    expect(route).toContain("WEBP");
  });

  test("keeps non-active inputs non-interactive and preview-free during recovery", () => {
    expect(review).toContain('input.status === "archived"');
    expect(review).toContain('input.status === "active" ? <Image');
    expect(review).toContain('input.status === "mapped"');
    expect(review).toContain("تم نقل الصورة إلى صور العقار");
  });

  test("keeps expired drafts on a cleanup-only recovery surface", () => {
    expect(page).toMatch(/reviewable[\s\S]*"expired"/u);
    expect(review).toContain('| "expired"');
    expect(actions).toContain('draft.status !== "rejected" && draft.status !== "expired"');
  });

  test("makes sales-agent property proposals read-only instead of offering a guaranteed failing write", () => {
    expect(agentCenter).toContain("canWriteDataEntryProperties");
    expect(intake).toContain("canWriteProperties");
    expect(review).toContain("canWriteProperties");
    expect(actions).toContain("includedProperties.size > 0");
    expect(actions).toContain("isPropertyCommandRole(membership.role)");
  });

  test("adds the final database hardening migration", () => {
    expect(existsSync(migrationPath)).toBe(true);
  });

  test("revalidates the initiating membership before exporting intake data to Gemini", () => {
    if (!existsSync(migrationPath)) return;
    const sql = read(migrationPath);
    expect(sql).toContain("JOIN public.organization_memberships AS initiator");
    expect(sql).toContain("initiator.status = 'active'");
    expect(sql).toContain("initiator.role IN ('owner', 'manager', 'sales_agent', 'operations')");
  });

  test("keeps generic data-entry run results behind the AAL2 boundary", () => {
    if (!existsSync(migrationPath)) return;
    const sql = read(migrationPath);
    expect(sql).toContain("CREATE OR REPLACE FUNCTION public.get_ai_run_result_v1");
    expect(sql).toContain("v_agent_kind = 'data_entry'");
    expect(sql).toContain("PERFORM public.require_ai_data_entry_aal2_v1()");
  });

  test("binds service image application to the confirmed image assignment and durable property result", () => {
    if (!existsSync(migrationPath)) return;
    const sql = read(migrationPath);
    expect(sql).toContain("confirmation_payload");
    expect(sql).toContain("imageInputIds");
    expect(sql).toContain("application_result");
    expect(sql).toContain("recordId");
    expect(sql).toContain("p_property_id::text");
  });
});
