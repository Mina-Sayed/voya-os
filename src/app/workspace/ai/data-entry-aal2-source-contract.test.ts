import { existsSync, readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const migrationPath = "supabase/migrations/20260824150000_enforce_ai_data_entry_aal2.sql";

describe("AI data-entry AAL2 migration coverage", () => {
  test("redefines every authenticated data-entry RPC with the AAL2 guard", () => {
    expect(existsSync(migrationPath)).toBe(true);
    const migration = readFileSync(migrationPath, "utf8");
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
      const marker = `CREATE OR REPLACE FUNCTION public.${rpc}`;
      expect(migration).toContain(marker);
      const body = migration.split(marker, 2)[1]?.split("CREATE OR REPLACE FUNCTION", 1)[0] ?? "";
      expect(body).toContain("PERFORM public.ai_data_entry_require_aal2_v1();");
    }
  });
});
