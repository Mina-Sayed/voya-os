# Security review: client registry foundation

`clients` is moved from browser-readable storage to narrowly scoped security-definer contracts.

- Direct `authenticated` `SELECT` and `INSERT` are revoked; the existing RLS policy is retained as defense in depth.
- `list_clients` returns only id, display name, and creation time and excludes `viewer`; `create_client` permits only owner, manager, sales agent, and operations.
- Both functions derive identity from `auth.uid()`, check active membership inside the database, set `search_path` to `pg_catalog`, and receive explicit execution grants.
- Creation is idempotent and writes `client.created` audit and outbox records atomically.
- The server action derives organization membership itself and never trusts a browser organization id.

This is not a lead/PII model: no contact details, consent, assignment, dedupe/merge, notes, or external messaging are persisted or displayed. Those fields require their own field-level policy and security review.
