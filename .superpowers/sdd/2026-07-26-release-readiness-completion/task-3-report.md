# Task 3 report: authenticated local Supabase browser fixture

## Status

The review findings are fixed in source, including a committed self-contained
runtime dependency closure. The harness unit suite passes. The latest production
browser run passed four scenarios and exposed one assertion error in the
suspended-membership case: Playwright returned the final public
`/access-pending` response, so the generic protected-response helper inspected
that static page instead of the preceding `/workspace` redirect response. The
assertion now inspects the redirected-from protected response, but the full suite
has not been rerun after that final correction.

## Implemented scope

- Added a dedicated disposable Supabase project on loopback ports `55321` and `55322`.
- Added hard guards for:
  - the exact project ID `voya-os-auth-e2e`;
  - `VOYA_AUTH_E2E_DISPOSABLE=1`;
  - the exact API origin `http://127.0.0.1:55321`;
  - the exact PostgreSQL host, port, user, and database identity
    `127.0.0.1:55322`, `postgres`, and `postgres`;
  - an exact local lifecycle-command allowlist that rejects linked operations,
    alternate databases, and extra arguments such as `--workdir`.
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
- Added an isolated production Next.js server mode. It copies only required
  source/config files into an OS temporary directory, symlinks `node_modules`,
  runs `next build --webpack`, then runs `next start` on the dedicated origin.
  Webpack is explicit because Turbopack rejects the isolated external
  `node_modules` symlink.
- Playwright and Next.js receive minimal allowlisted child environments. Ambient
  `DATABASE_URL`, `VOYA_APP_URL`, Supabase access/service secrets, project
  references, unrelated variables, and fixture passwords for Next.js are
  excluded.
- A failed `supabase start` attempt now still triggers `supabase stop`, covering
  partially created local stacks.
- Commit `f93ba9f` adds only the runtime dependency closure needed by the five
  scenarios: workspace organization selection/context, server cookie handling,
  and the Supabase session-refresh proxy. Unrelated workspace feature
  actions/forms and broader remediation files were not included.

## Root causes found

1. The first local startup exceeded the original 180-second process timeout while Docker images were being downloaded.
2. The installed global Supabase CLI was `2.75.0`, while `.temp` image metadata was current (`gotrue v2.193.1`). Both status credentials returned local Auth `bad_jwt`/403. A pinned current CLI fixed Auth user creation.
3. Organization seeding through PostgREST returned PostgreSQL `42501`. This was expected from the migration contract: public table writes are revoked. Seeding was moved to the guarded local database connection rather than weakening grants.
4. Port 3000 was occupied by an existing Next.js process. Reuse remained disabled to avoid testing against stale configuration.
5. Moving to port 3102 still hit Next.js 16's single-development-server lock for the repository's `.next/dev`.
6. The first isolated project used a symlinked `src` directory. Next.js compiled only `/_not-found`, so the implementation copies `src` and required config files.
7. The first review-fix production run used Turbopack, which rejected the
   external `node_modules` symlink. The production build now uses the documented
   `--webpack` option.
8. Production mode correctly rejected local HTTP Supabase by default. A narrow
   exception now requires both `VOYA_AUTH_E2E_LOCAL=1` and the exact dedicated
   API origin; alternate loopback ports, hosts, and paths remain rejected.
9. A cache assertion was incorrectly applied to the final public
   `/access-pending` response after a protected redirect. It now obtains and
   checks the preceding `/workspace` response from Playwright's redirect chain.

## Verification evidence

| Check | Result |
| --- | --- |
| `node --test scripts/test-authenticated-browser.test.mjs` | PASS: 14 tests, 0 failures |
| Review-fix red phase | PASS: 7 intended failures observed before implementation; an additional production-build regression failed before adding `--webpack` |
| Red/green credential precedence regression | RED observed with new keys selected; GREEN after preferring local `ANON_KEY`/`SERVICE_ROLE_KEY` |
| Red/green pinned CLI invocation regression | RED observed with missing builder; GREEN with exact `supabase@2.109.1` invocation |
| Red/green local psql guard regression | RED observed with missing builder; GREEN with remote rejection and password absent from argv |
| `npx vitest run src/features/auth/workspace-context.test.ts src/lib/supabase/proxy-client.test.ts` | PASS: 15 tests |
| `npm test` | PASS: 35 files, 100 tests |
| `npm run lint` | PASS |
| Staged-only dependency worktree `next build` | PASS: all workspace routes dynamic and Proxy emitted |
| `npm audit --omit=dev --audit-level=high` | FAIL: one high and one moderate PostCSS advisory through Next.js; suggested force fix would downgrade Next.js and was not applied |
| First production auth-local review run | FAIL before Playwright: Turbopack rejected the external dependency symlink; fixed with `next build --webpack` |
| Latest production auth-local review run | 4 passed, 1 assertion failure: single, multi, forged, and refresh passed; suspended reached the public redirect target but the cache helper inspected that final response |
| Final clean committed auth-local rerun | NOT RUN after the redirect-chain assertion correction |

## Security review

No new Critical or High source-code finding was identified in the Task 3-owned
implementation. The recorded high dependency advisory remains open.

- Remote Supabase and database hosts fail before reset, seeding, or Playwright.
- `supabase db push --linked`, linked resets, arbitrary database URLs, and arbitrary CLI commands are rejected.
- Synthetic credentials are generated per run and stay in process memory.
- Service-role and database credentials are not logged, written to disk, or exposed to the app/browser.
- SQL interpolation is limited to generated or Auth-returned values validated as UUIDs plus a `randomUUID()` slug.
- The temporary Next.js project excludes `.env.local`; its exact generated directory is removed on graceful shutdown.
- Production-mode local HTTP is allowed only under the explicit test flag and
  exact dedicated API origin.
- The remaining dependency-audit finding is recorded above and is not caused by this Task 3 dependency set.

## Remaining gate

Run `npm run test:e2e:auth-local` once from an isolated clean checkout containing
the dependency and harness-fix commits. The latest full run preceded the final
redirect-chain assertion correction, so Task 3 must not yet be described as
fully verified.
