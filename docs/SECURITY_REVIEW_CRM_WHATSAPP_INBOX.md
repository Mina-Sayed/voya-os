# Security review: CRM and staff-operated WhatsApp inbox

## Scope

Reviewed migration `20260801000200_crm_whatsapp_inbox.sql`, the server actions under `src/app/workspace/whatsapp/`, and the Design C inbox component.

## Findings

No Critical or High findings were reproduced in the local SQL suite. The browser role has no direct privileges on contact, consent, channel, conversation, message, or note tables. RPCs require an active membership in the requested organization and apply role checks before reading or mutating data. The SQL regression covers idempotent contact/message writes, audit/outbox evidence, cross-tenant reads, and suspended-user denial.

## Explicit release blockers

- No provider webhook adapter is enabled.
- No provider credential or callback-signature verification is implemented.
- Outbound workers must not be enabled until consent scope, retention, quiet hours, retry/dead-letter behavior, and channel ownership are approved.

## Evidence

`VOYA_DB_TEST=1 DATABASE_URL=<local *_test database> npm run test:db` passed, including `supabase/tests/crm_whatsapp_inbox.sql`. The UI labels queued replies as not delivered and does not expose secrets or raw provider payloads.
