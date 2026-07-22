# Security review: booking draft workspace

The `/workspace/bookings` surface creates only `draft` bookings through the reviewed `create_booking_draft` command.

- The page and action derive the user and a unique active membership on the server; neither accepts `organization_id`, role, or actor identity from the browser.
- The page permits owner, manager, sales agent, and operations only. The database command repeats this authorization check.
- The action validates that the stay is non-empty before calling the database; the database check is still authoritative.
- The form describes the half-open stay convention and explicitly says that a draft neither confirms inventory nor creates financial effects.
- The only option reads use tenant-authorized RPCs. The client registry contract returns no contact/consent data.
- Confirmation, cancellation, pricing, payments, approval execution, and notification delivery are unavailable from this surface.
