-- Voya OS: durable transactional outbox foundation.
-- Worker runtime, provider channels, retention, and retry timings remain
-- deployment decisions; browser roles never access this table.

CREATE TABLE public.outbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type ~ '^[a-z][a-z0-9_]*([.][a-z][a-z0-9_]*)+$'),
  schema_version integer NOT NULL CHECK (schema_version > 0),
  dedupe_key text NOT NULL CHECK (char_length(btrim(dedupe_key)) > 0),
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  state text NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending', 'processing', 'retry_wait', 'completed', 'dead_letter')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  locked_by text,
  locked_until timestamptz,
  last_error_code text,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT outbox_event_lease_consistency CHECK (
    (state = 'processing') = (locked_by IS NOT NULL AND locked_until IS NOT NULL)
  ),
  CONSTRAINT outbox_event_dedupe_unique UNIQUE (organization_id, event_type, dedupe_key)
);

CREATE INDEX outbox_events_claim_idx
  ON public.outbox_events (available_at, created_at)
  WHERE state IN ('pending', 'retry_wait');
CREATE INDEX outbox_events_lease_idx
  ON public.outbox_events (locked_until)
  WHERE state = 'processing';

CREATE TRIGGER outbox_events_set_updated_at
  BEFORE UPDATE ON public.outbox_events
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.outbox_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.outbox_events FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.outbox_events FROM PUBLIC;
