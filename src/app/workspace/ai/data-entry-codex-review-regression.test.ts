import { existsSync, readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const hardeningMigration = "supabase/migrations/20260824043000_archive_terminal_ai_data_entry_inputs.sql";
const recoveryMigration = "supabase/migrations/20260824040000_finalize_ai_data_entry_recovery.sql";
const bootstrapAuth = "supabase/tests/bootstrap_auth.sql";

function read(path: string): string {
  return readFileSync(path, "utf8");
}

function functionBody(sql: string, name: string): string {
  const marker = `CREATE OR REPLACE FUNCTION public.${name}`;
  const after = sql.split(marker, 2)[1] ?? "";
  return after.split("$$;", 1)[0] ?? "";
}

describe("Codex review regressions for AI data entry", () => {
  test("requires MFA AAL2 inside every authenticated AI data-entry RPC", () => {
    expect(existsSync(hardeningMigration)).toBe(true);
    const sql = read(hardeningMigration);
    expect(sql).toContain("CREATE OR REPLACE FUNCTION public.require_ai_data_entry_aal2_v1");

    const authenticatedRpcNames = [
      "create_ai_data_entry_draft_v1",
      "register_ai_data_entry_input_v1",
      "submit_ai_data_entry_draft_v1",
      "list_ai_data_entry_drafts_v1",
      "get_ai_data_entry_draft_v1",
      "list_ai_data_entry_inputs_v1",
      "claim_ai_data_entry_confirmation_v3",
      "reject_ai_data_entry_draft_v1",
    ] as const;

    for (const name of authenticatedRpcNames) {
      const body = functionBody(sql, name);
      expect(body, `${name} must be redefined by the final hardening migration`).not.toBe("");
      expect(body, `${name} must enforce AAL2 before delegating`).toContain("require_ai_data_entry_aal2_v1");
    }

    const helper = functionBody(sql, "require_ai_data_entry_aal2_v1");
    expect(helper).toContain("auth.jwt()");
    expect(helper).toContain("'aal2'");
    expect(helper).toContain("ERRCODE = '42501'");
  });

  test("keeps the local Supabase auth shim capable of exercising AAL claims", () => {
    const sql = read(bootstrapAuth);
    expect(sql).toContain("CREATE OR REPLACE FUNCTION auth.jwt()");
    expect(sql).toContain("request.jwt.claim.aal");
  });

  test("registers an AI property image and maps its intake input in one database transaction", () => {
    const sql = read(hardeningMigration);
    expect(sql).toContain("RENAME TO register_property_image_without_ai_mapping_v1");
    const registration = functionBody(sql, "register_property_image_v1");
    expect(registration).not.toBe("");
    expect(registration).toContain("require_ai_data_entry_aal2_v1");
    expect(registration).toContain("register_property_image_without_ai_mapping_v1");
    expect(registration).toContain("UPDATE public.ai_data_entry_inputs");
    expect(registration).toContain("SET status = 'mapped'");
    expect(registration).toContain("confirmation_execution_heartbeat_at");
    expect(registration).toContain("ai.data_entry.input.mapped");
  });

  test("keeps the authenticated AI image path at AAL2 while worker mapping stays service-only", () => {
    const sql = read(hardeningMigration);
    const recoverySql = read(recoveryMigration);
    const registration = functionBody(sql, "register_property_image_v1");
    expect(registration).toContain("IF p_idempotency_key IS NULL OR p_idempotency_key NOT LIKE 'ai-data-entry:%'");
    expect(registration).toContain("PERFORM public.require_ai_data_entry_aal2_v1()");
    expect(recoverySql).toContain("REVOKE ALL ON FUNCTION public.mark_ai_data_entry_input_mapped_v2(uuid,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC, anon, authenticated");
    expect(recoverySql).toContain("GRANT EXECUTE ON FUNCTION public.mark_ai_data_entry_input_mapped_v2(uuid,uuid,uuid,uuid,uuid,uuid) TO service_role");
  });
});
