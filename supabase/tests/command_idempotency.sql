-- Normalize retries and install deterministic race barriers for the harness.
\set ON_ERROR_STOP on

INSERT INTO auth.users (id, email, email_confirmed_at)
VALUES (
  '77777777-7777-7777-7777-777777777777',
  'commands@example.test',
  timezone('utc', now())
)
ON CONFLICT (id) DO UPDATE
SET email = EXCLUDED.email,
    email_confirmed_at = EXCLUDED.email_confirmed_at;

INSERT INTO public.profiles (id, display_name)
VALUES ('77777777-7777-7777-7777-777777777777', 'Command race user');

INSERT INTO public.organizations (id, name, slug)
VALUES ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'Command race tenant', 'command-race-tenant');

INSERT INTO public.organization_memberships (id, organization_id, user_id, role, status)
VALUES (
  'dddddddd-0000-0000-0000-000000000001',
  'dddddddd-dddd-dddd-dddd-dddddddddddd',
  '77777777-7777-7777-7777-777777777777',
  'owner',
  'active'
);

INSERT INTO public.clients (id, organization_id, display_name)
VALUES (
  'dddddddd-0000-0000-0000-000000000002',
  'dddddddd-dddd-dddd-dddd-dddddddddddd',
  'Command race client'
);

INSERT INTO public.whatsapp_channels (
  id, organization_id, provider, external_channel_id, display_name, created_by_membership_id
)
VALUES (
  'dddddddd-0000-0000-0000-000000000003',
  'dddddddd-dddd-dddd-dddd-dddddddddddd',
  'test',
  'command-race-channel',
  'Command race channel',
  'dddddddd-0000-0000-0000-000000000001'
);

INSERT INTO public.whatsapp_conversations (
  id, organization_id, channel_id, external_conversation_key, created_at, updated_at
)
VALUES (
  'dddddddd-0000-0000-0000-000000000004',
  'dddddddd-dddd-dddd-dddd-dddddddddddd',
  'dddddddd-0000-0000-0000-000000000003',
  'command-race-conversation',
  timezone('utc', now()),
  timezone('utc', now())
);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '77777777-7777-7777-7777-777777777777', false);

DO $$
DECLARE
  v_first uuid;
  v_retry uuid;
BEGIN
  v_first := public.create_crm_contact_method(
    'dddddddd-dddd-dddd-dddd-dddddddddddd', 'email', 'guest@example.test',
    'Guest', NULL, 'dddddddd-0000-0000-0000-000000000002', 'normalized-contact', NULL
  );
  v_retry := public.create_crm_contact_method(
    'dddddddd-dddd-dddd-dddd-dddddddddddd', 'email', 'guest@example.test',
    'Guest', NULL, 'dddddddd-0000-0000-0000-000000000002', '  normalized-contact  ', NULL
  );
  IF v_first <> v_retry THEN RAISE EXCEPTION 'contact retry returned a different winner'; END IF;

  v_first := public.create_whatsapp_message(
    'dddddddd-dddd-dddd-dddd-dddddddddddd',
    'dddddddd-0000-0000-0000-000000000004',
    'Hello from the normalized retry', 'normalized-message', NULL
  );
  v_retry := public.create_whatsapp_message(
    'dddddddd-dddd-dddd-dddd-dddddddddddd',
    'dddddddd-0000-0000-0000-000000000004',
    'Hello from the normalized retry', '  normalized-message  ', NULL
  );
  IF v_first <> v_retry THEN RAISE EXCEPTION 'message retry returned a different winner'; END IF;

  v_first := public.create_ai_run_request(
    'dddddddd-dddd-dddd-dddd-dddddddddddd', 'manager',
    'Review command reliability', 'normalized-ai-run', NULL
  );
  v_retry := public.create_ai_run_request(
    'dddddddd-dddd-dddd-dddd-dddddddddddd', 'manager',
    'Review command reliability', '  normalized-ai-run  ', NULL
  );
  IF v_first <> v_retry THEN RAISE EXCEPTION 'AI retry returned a different winner'; END IF;

  v_first := public.create_operations_task(
    'dddddddd-dddd-dddd-dddd-dddddddddddd', 'reliability.review',
    'Review command retries', NULL, NULL, NULL, NULL, 'normalized-task', NULL
  );
  v_retry := public.create_operations_task(
    'dddddddd-dddd-dddd-dddd-dddddddddddd', 'reliability.review',
    'Review command retries', NULL, NULL, NULL, NULL, '  normalized-task  ', NULL
  );
  IF v_first <> v_retry THEN RAISE EXCEPTION 'task retry returned a different winner'; END IF;

  v_first := public.create_transport_request(
    'dddddddd-dddd-dddd-dddd-dddddddddddd', 'airport_transfer', 'Guest',
    'Airport', 'Voya property', timestamptz '2027-05-01 10:00:00+00',
    2, NULL, NULL, NULL, 'normalized-transport', NULL
  );
  v_retry := public.create_transport_request(
    'dddddddd-dddd-dddd-dddd-dddddddddddd', 'airport_transfer', 'Guest',
    'Airport', 'Voya property', timestamptz '2027-05-01 10:00:00+00',
    2, NULL, NULL, NULL, '  normalized-transport  ', NULL
  );
  IF v_first <> v_retry THEN RAISE EXCEPTION 'transport retry returned a different winner'; END IF;
END;
$$;

RESET ROLE;

CREATE OR REPLACE FUNCTION public.test_delay_idempotency_race_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.idempotency_key LIKE 'race-%' THEN
    PERFORM pg_sleep(0.5);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER test_delay_crm_contact_race
  BEFORE INSERT ON public.crm_contact_methods
  FOR EACH ROW EXECUTE FUNCTION public.test_delay_idempotency_race_insert();
CREATE TRIGGER test_delay_whatsapp_message_race
  BEFORE INSERT ON public.whatsapp_message_events
  FOR EACH ROW EXECUTE FUNCTION public.test_delay_idempotency_race_insert();
CREATE TRIGGER test_delay_ai_run_race
  BEFORE INSERT ON public.ai_runs
  FOR EACH ROW EXECUTE FUNCTION public.test_delay_idempotency_race_insert();
CREATE TRIGGER test_delay_operations_task_race
  BEFORE INSERT ON public.operations_tasks
  FOR EACH ROW EXECUTE FUNCTION public.test_delay_idempotency_race_insert();
CREATE TRIGGER test_delay_transport_request_race
  BEFORE INSERT ON public.transport_requests
  FOR EACH ROW EXECUTE FUNCTION public.test_delay_idempotency_race_insert();
