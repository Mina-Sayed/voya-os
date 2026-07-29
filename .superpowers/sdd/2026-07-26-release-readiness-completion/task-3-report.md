# Task 3 report: authenticated local Supabase browser fixture

## Status

Implementation is coherent and Task 3 is fully verified. After the interrupted
worker's source-copy correction, the root agent reran the complete disposable
local suite successfully: all five authenticated Chromium scenarios passed and
the harness exited cleanly.

## Implemented scope

- Added a dedicated disposable Supabase project on loopback ports `55321` and `55322`.
- Added hard guards for:
  - the exact project ID `voya-os-auth-e2e`;
  - `VOYA_AUTH_E2E_DISPOSABLE=1`;
  - loopback-only API and PostgreSQL URLs;
  - an allowlist of local lifecycle commands that rejects linked pushes/resets.
- Pinned every Supabase lifecycle call to `npx --yes supabase@2.109.1` to avoid the installed global CLI `2.75.0` using incompatible current Auth image metadata.
- Creates real synthetic users through the local Supabase Auth admin API.
- Seeds organizations, profiles, and memberships through guarded loopback `psql`. This preserves the production schema's deny-by-default PostgREST write grants; no migration or table grant was weakened for tests.
- Keeps the database password in `PGPASSWORD` child-process memory and never places it in command arguments, files, or output.
- Passes only the local anon key and synthetic credentials to Playwright. The service-role key is never passed to the browser or app server.
- Added real Supabase password sign-in and browser cookies without an auth bypass route.
- Added Playwright scenarios for:
  - single-membership workspace access;
  - multi-membership selection and persistence;
  - forged organization-cookie fail-closed behavior;
  - suspended membership denial;
  - expired access-token refresh;
  - absence of prerender/shared-cache response markers.
- Uses a dedicated application origin, `http://127.0.0.1:3102`, and refuses remote/non-approved origins.
- Added an isolated Next.js server mode. It copies only required source/config files into an OS temporary directory, symlinks `node_modules`, excludes `.env.local`, removes fixture passwords from the server environment, and cleans up on graceful shutdown.

## Root causes found

1. The first local startup exceeded the original 180-second process timeout while Docker images were being downloaded.
2. The installed global Supabase CLI was `2.75.0`, while `.temp` image metadata was current (`gotrue v2.193.1`). Both status credentials returned local Auth `bad_jwt`/403. A pinned current CLI fixed Auth user creation.
3. Organization seeding through PostgREST returned PostgreSQL `42501`. This was expected from the migration contract: public table writes are revoked. Seeding was moved to the guarded local database connection rather than weakening grants.
4. Port 3000 was occupied by an existing Next.js process. Reuse remained disabled to avoid testing against stale configuration.
5. Moving to port 3102 still hit Next.js 16's single-development-server lock for the repository's `.next/dev`.
6. The first isolated project used a symlinked `src` directory. Next.js compiled only `/_not-found`, and Playwright timed out after 60 seconds waiting for the server. The implementation now copies `src` and required config files into the temporary project; the final rerun passed all five scenarios.

## Verification evidence

| Check | Result |
| --- | --- |
| `node --test scripts/test-authenticated-browser.test.mjs` | PASS: 9 tests, 0 failures |
| Red/green credential precedence regression | RED observed with new keys selected; GREEN after preferring local `ANON_KEY`/`SERVICE_ROLE_KEY` |
| Red/green pinned CLI invocation regression | RED observed with missing builder; GREEN with exact `supabase@2.109.1` invocation |
| Red/green local psql guard regression | RED observed with missing builder; GREEN with remote rejection and password absent from argv |
| Focused ESLint on all owned JS/TS files | PASS |
| `npx tsc --noEmit` | BLOCKED: the existing `.next/dev/types/validator.ts` is malformed at lines 107/111 while another Next development server owns the repository `.next` directory |
| `npm audit --omit=dev --audit-level=high` | FAIL: one high and one moderate PostCSS advisory through Next.js; suggested force fix would downgrade Next.js and was not applied |
| Final `npm run test:e2e:auth-local` | PASS: 5 authenticated Chromium scenarios, 0 failures, harness exit 0 |
| Cleanup check | PASS: no Task 3 Supabase containers, loopback listeners, harness processes, or temporary isolated project remained |

## Security review

No Critical or High security finding was identified in the Task 3-owned implementation.

- Remote Supabase and database hosts fail before reset, seeding, or Playwright.
- `supabase db push --linked`, linked resets, arbitrary database URLs, and arbitrary CLI commands are rejected.
- Synthetic credentials are generated per run and stay in process memory.
- Service-role and database credentials are not logged, written to disk, or exposed to the app/browser.
- SQL interpolation is limited to generated or Auth-returned values validated as UUIDs plus a `randomUUID()` slug.
- The temporary Next.js project excludes `.env.local`; its exact generated directory is removed on graceful shutdown.
- The remaining dependency-audit finding is recorded above and is not caused by this Task 3 dependency set.

## Remaining gate

None for Task 3. Broader repository verification remains owned by Task 7.
