import { existsSync, readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const aal2Migration = "supabase/migrations/20260824150000_enforce_ai_data_entry_aal2.sql";
const imageRecoveryMigration = "supabase/migrations/20260824151000_harden_ai_data_entry_image_mapping.sql";

describe("Codex P1 regression contracts", () => {
  test("all authenticated AI data-entry RPCs enforce aal2 at the database boundary", () => {
    expect(existsSync(aal2Migration)).toBe(true);
    if (!existsSync(aal2Migration)) return;
    const migration = readFileSync(aal2Migration, "utf8");
    expect(migration).toContain("auth.jwt() ->> 'aal'");
    expect(migration).toContain("AI data-entry requires MFA assurance level 2");
    for (const rpc of [
      "create_ai_data_entry_draft_v1",
      "register_ai_data_entry_input_v1",
      "submit_ai_data_entry_draft_v1",
      "get_ai_data_entry_draft_v1",
      "list_ai_data_entry_drafts_v1",
      "list_ai_data_entry_inputs_v1",
      "claim_ai_data_entry_confirmation_v3",
      "reject_ai_data_entry_draft_v1",
    ]) {
      expect(migration).toContain(`CREATE OR REPLACE FUNCTION public.${rpc}`);
    }
  });

  test("AI property-image registration and intake mapping share one atomic database transaction", () => {
    expect(existsSync(imageRecoveryMigration)).toBe(true);
    if (!existsSync(imageRecoveryMigration)) return;
    const migration = readFileSync(imageRecoveryMigration, "utf8");
    expect(migration).toContain("CREATE OR REPLACE FUNCTION public.apply_ai_data_entry_property_image_v1");
    expect(migration).toContain("INSERT INTO public.property_images");
    expect(migration).toContain("UPDATE public.ai_data_entry_inputs");
    expect(migration).toContain("GRANT EXECUTE ON FUNCTION public.apply_ai_data_entry_property_image_v1");
    expect(migration).toContain("TO service_role");
  });

  test("the confirmation action no longer performs register then map as separate commits", () => {
    const source = readFileSync("src/app/workspace/ai/data-entry-actions.ts", "utf8");
    expect(source).toContain('serviceClient.rpc("apply_ai_data_entry_property_image_v1"');
    expect(source).not.toContain('client.rpc("register_property_image_v1"');
    expect(source).not.toContain('serviceClient.rpc("mark_ai_data_entry_input_mapped_v2"');
  });
});
