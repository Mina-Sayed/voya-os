# ADR-022 — WhatsApp AI Phase 1 uses existing inbox/outbox and human confirmation

**Status:** Accepted for feature branch; managed rollout gated

## Decision

Implement one `VOYA WhatsApp Agent` inside the existing Next.js + Supabase
modular monolith. Extend the current WhatsApp conversation/message rows, reuse
private `ai-intake` and `property-images` storage, and process
`whatsapp.ai.respond_requested` through the existing lease-owned outbox worker.

The model may return only the six validated fields `conversationType`, `facts`,
`missingFields`, `reply`, `recommendedAction`, and `confidence`. Application
code, not the model, decides whether to project a deterministic existing CRM
lead or queue a reply. Owner/property data remains a conversation draft until
an authenticated inventory role confirms it through the existing owner,
property, ownership, and property-image commands.

The existing V1 property command names remain in use. The old signatures remain
available; additive extended V1 overloads carry furnished-rental fields because
PostgreSQL cannot change an existing function's return signature in place. No
`create_property_v2` or `update_property_v2` is introduced.

Phase 2 CRM follow-up automation and provider configuration/deployment are out
of scope for this branch.

## Consequences

- Webhook latency is limited to signature verification, persistence, and enqueue.
- Retries, idempotency, audit evidence, tenant checks, and human takeover remain
  in existing boundaries.
- Local SQL, unit, build, and authenticated browser checks prove checkout
  behavior only; managed Supabase/Vercel/Meta/Gemini state still needs a
  separately approved rollout and dated verification.

## References

- `supabase/migrations/20260827153809_whatsapp_ai_agent_phase1.sql`
- `supabase/tests/whatsapp_ai_agent_phase1.sql`
- `supabase/functions/outbox-dispatch/index.ts`
- `src/domain/ai/whatsapp-agent-contract.ts`
