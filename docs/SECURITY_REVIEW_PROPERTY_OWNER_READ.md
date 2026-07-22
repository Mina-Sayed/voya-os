# Security Review: Property Owner Read UI

Date: 2026-07-22

## Controls verified

- The Next.js route checks the authenticated user and resolves exactly one
  active membership before requesting data.
- The route calls a tenant-qualified RPC using the organization derived from
  that membership; it never accepts a tenant identifier from the URL or UI.
- The RPC independently requires an active `owner`, `manager`, or `operations`
  role and returns only ID, display name, status, and creation time.
- Browser roles retain no direct `property_owners` table privileges.
- Unauthenticated navigation to `/workspace/property-owners` redirects to the
  configured sign-in boundary; Playwright covers this path.
- The create form sends only a display name and a client-generated idempotency
  token. The Server Action derives the authenticated user and organization on
  the server, invokes the protected RPC, maps only safe error classes, and
  revalidates the page after success.

## Deliberate limitations

Only property-owner creation is enabled. Edit actions, ownership-period history,
attachments, settlements, and field-level expansions require separate commands
and policy review. The page cannot expose financial or settlement data.
