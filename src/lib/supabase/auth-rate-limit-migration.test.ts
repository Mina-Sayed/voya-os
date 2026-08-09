import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const migrationPath = resolve(
  process.cwd(),
  "supabase/migrations/20260809000100_harden_auth_rate_limit_policy.sql",
);

describe("auth rate-limit policy migration", () => {
  it("removes the caller-configurable RPC and keeps all public policy database-owned", () => {
    const sql = readFileSync(migrationPath, "utf8");

    expect(sql).toMatch(/DROP FUNCTION public\.consume_auth_rate_limit\s*\(text, text, integer, integer\)/u);
    expect(sql).toMatch(/WHEN 'password_sign_up' THEN/u);
    expect(sql).toMatch(/GRANT EXECUTE ON FUNCTION public\.consume_auth_rate_limit\(text, text\) TO anon, authenticated/u);
    expect(sql).not.toMatch(/GRANT EXECUTE ON FUNCTION public\.consume_auth_rate_limit\(text, text, integer, integer\)/u);
  });
});
