# Auth/AuthZ Scope Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the four validated Auth/AuthZ bypasses in the current checkout: cross-tenant legacy lead reads, AAL1 team administration, hidden task mutation, and CRM child-record scope bypasses.

**Architecture:** Add one forward-only PostgreSQL migration. Preserve existing function bodies by renaming them to private compatibility implementations, then expose stable wrappers that enforce AAL2, tenant membership, role, and assignment scope before delegating. Keep browser table grants revoked and add disposable-database regression proofs.

**Tech Stack:** PostgreSQL/Supabase SECURITY DEFINER RPCs, SQL regression tests, Node migration harness.

## Global Constraints

- Organization and membership are derived and rechecked in PostgreSQL; client-supplied organization, membership, and resource IDs never grant authority.
- Workspace reads and sensitive mutations require verified MFA AAL2 at the database boundary.
- Existing RPC signatures and legitimate owner/manager behavior remain compatible.
- Migrations are forward-only; do not rewrite historical migrations or touch managed Supabase.
- Preserve unrelated dirty work and the untracked `.opencode/` directory.

## Review Focus

- A password-only owner must receive `42501` before any team read or mutation.
- An authenticated outsider must not receive legacy lead rows when the selected organization has no membership.
- An operations member may mutate only unassigned or self-assigned tasks; owner/manager oversight remains available.
- A sales agent may read or mutate CRM child records only for unassigned or self-assigned leads; owner/manager/operations/viewer behavior remains intact.
- Legacy compatibility signatures must remain defined but wrappers must own the browser grants.

### Task 1: Add database authorization wrappers

**Files:**
- Create: `supabase/migrations/20260922000300_close_authz_scope_gaps.sql`
- Modify: none

- [ ] Add the `v_role IS NULL` fail-closed condition to `list_leads` and keep its tenant/assignment filtering.
- [ ] Rename team member read/admin RPC implementations and expose AAL2 wrappers with the existing signatures and grants.
- [ ] Add a scoped task-status wrapper that allows owner/manager oversight and restricts operations members to unassigned/self-assigned tasks.
- [ ] Add a private lead-visibility helper and wrappers for CRM activity/follow-up reads and writes, preserving role-specific behavior.
- [ ] Revoke `PUBLIC`, `anon`, and authenticated execution from renamed implementations; grant only the stable wrappers to `authenticated`.

### Task 2: Add regression proofs

**Files:**
- Create: `supabase/tests/authz_scope_remediation.sql`
- Modify: `scripts/test-database-foundation.mjs`
- Modify: `supabase/tests/team_member_commands_v1.sql`

- [ ] Set owner `aal1` and prove team reads/mutations fail before any state change.
- [ ] Prove owner `aal2` still performs the existing legitimate team operations.
- [ ] Create an owner-assigned task and prove an operations member cannot update it while an owner can.
- [ ] Create an owner-assigned lead and prove a different sales agent cannot list/create/complete child CRM records for it.
- [ ] Prove an outsider cannot call legacy `list_leads` for another organization.
- [ ] Register the new migration and test in the disposable database runner.

### Task 3: Verify

- [ ] Run `npm run lint`.
- [ ] Run `npm run typecheck`.
- [ ] Run deterministic Vitest with one worker and the normal Vitest command if resources permit.
- [ ] Run `VOYA_DB_TEST=1 DATABASE_URL=postgresql://...@127.0.0.1:<port>/voya_authz_test npm run test:db` on disposable PostgreSQL.
- [ ] Inspect the final diff and confirm only the migration, SQL proofs, runner registration, test expectation updates, and plan are changed; preserve `.opencode/`.
