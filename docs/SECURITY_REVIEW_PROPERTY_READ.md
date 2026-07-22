# Security review: property read contract

## Scope

`list_properties` and `/workspace/properties` expose only a property's identifier, code, name, timezone, status, and creation time.

## Controls verified

- The server route derives the authenticated user and active organization membership; it never accepts an organization id from the browser.
- The RPC receives the server-derived organization id and checks that the caller has an active membership before returning rows.
- The function has a fixed `pg_catalog` search path and explicit `authenticated` execution grant.
- Its result is organization-scoped and contains no booking, client, owner, payment, commission, expense, settlement, or audit payload.
- Existing direct `properties` reads remain intentionally RLS-protected for every active member, including `viewer` and `sales_agent`; the integration test proves a suspended member sees no direct rows and cannot use the RPC.
- The workspace route redirects unauthenticated or unconfigured requests to sign-in and membership failures to the neutral access-pending page.

## Residual risks and follow-up

- Property codes and names are operational data. Any future column with access credentials, owner settlement details, or legal identity data must not be added to this RPC or the browser-readable table contract without a new review.
- Mutations remain server-owned commands; no direct browser insert/update/delete grant is added here.
- Rate limits and telemetry belong at the edge/server boundary before public traffic is enabled.
