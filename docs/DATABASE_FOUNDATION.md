# Tenancy and Booking Database Foundation

This migration is the first production-data boundary for Voya OS. It is deliberately narrower than the product schema described in the parent documentation: it covers profile, organization, active membership, property, client, and booking identity only.

## Enforced invariants

- Tenant-owned operational roots use non-null `organization_id`.
- A booking can only reference a property and client in its own organization, through tenant-qualified composite foreign keys.
- The only browser-role grants in this slice are reads. Forced RLS uses an active `auth.uid()` membership check; a suspended or cross-tenant user receives no rows.
- Confirmed occupancy uses `[check_in, check_out)` dates. The partial GiST exclusion constraint rejects confirmed overlaps for the same property and organization while allowing checkout/check-in adjacency and overlapping drafts.
- Booking writes remain unavailable to `authenticated`. A later server-side command must enforce role, approval, idempotency, audit, outbox, availability-block locking, and error mapping before it is granted a write path.

## Running the integration test

The test intentionally refuses all but a local database whose name ends in `_test`.

```bash
docker run --rm --detach --name voya-os-db-test \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=voya_test \
  -p 127.0.0.1:54329:5432 postgres:17-alpine

VOYA_DB_TEST=1 \
DATABASE_URL='postgresql://postgres:postgres@127.0.0.1:54329/voya_test' \
npm run test:db
```

The test drops and recreates the `public` schema in that explicitly named disposable database. Stop the container when finished:

```bash
docker rm --force voya-os-db-test
```

## Important assumptions and open decisions

- The migration assumes a Supabase project supplies `auth.users`, `auth.uid()`, and the `authenticated` role. The integration harness supplies minimal test-only equivalents.
- The organization bootstrap/invitation and last-owner rules are intentionally absent. Apply this migration through privileged, audited migration credentials; do not expose table writes to the browser to bootstrap tenants.
- Availability blocks cannot share this cross-table exclusion constraint. Before enabling confirmation commands, adopt the documented per-property transaction lock or a reviewed unified occupancy design and test concurrent block/confirmation behavior.
- No financial table, approval threshold, payment workflow, currency policy, or data-retention rule is represented here. Those require product and finance approval.
- The PostgreSQL version must support the GiST and `btree_gist` features used by this migration. Normal `UNIQUE` semantics intentionally allow multiple null idempotency keys.
- The GitHub workflow requires a repository `SNYK_TOKEN` secret. It is intentionally not optional: Snyk and Trivy are required security gates before deployment.
