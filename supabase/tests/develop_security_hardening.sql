-- Regression coverage for the develop security/integrity remediation.
\set ON_ERROR_STOP on

-- Self-service organization creation must serialize on the authenticated user
-- inside the same transaction as the membership check and inserts.
DO $$
DECLARE
  definition text;
BEGIN
  SELECT pg_get_functiondef('public.create_organization(text,text,text,uuid)'::regprocedure)
  INTO definition;
  IF position('pg_advisory_xact_lock' IN definition) = 0 THEN
    RAISE EXCEPTION 'create_organization must acquire a transaction-level advisory lock before the active-membership check';
  END IF;
END;
$$;

-- The product role catalog must be provisionable through the same invitation
-- and role-change boundaries used by the Team workspace.
DO $$
DECLARE
  invite_definition text;
  role_definition text;
BEGIN
  SELECT pg_get_functiondef('public.invite_organization_member_v1(uuid,text,text,text,text,uuid)'::regprocedure)
  INTO invite_definition;
  SELECT pg_get_functiondef('public.change_organization_member_role(uuid,uuid,text,uuid)'::regprocedure)
  INTO role_definition;
  IF position('sales_agent' IN invite_definition) = 0 OR position('accountant' IN invite_definition) = 0 THEN
    RAISE EXCEPTION 'team invitations must support sales_agent and accountant roles';
  END IF;
  IF position('sales_agent' IN role_definition) = 0 OR position('accountant' IN role_definition) = 0 THEN
    RAISE EXCEPTION 'team role changes must support sales_agent and accountant roles';
  END IF;
END;
$$;

-- Fleet creation needs explicit idempotency-key overloads instead of relying on
-- a per-attempt request/correlation id.
DO $$
BEGIN
  IF to_regprocedure('public.create_fleet_vehicle(uuid,text,text,text,integer,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'idempotent create_fleet_vehicle overload is missing';
  END IF;
  IF to_regprocedure('public.create_fleet_driver(uuid,text,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'idempotent create_fleet_driver overload is missing';
  END IF;
END;
$$;

-- A WhatsApp provider send has no provider-side idempotency guarantee in the
-- current adapter. If a worker dies after sending and its lease expires, that
-- processing event is ambiguous and must never be automatically reclaimed for
-- another send. It must become needs_review instead.
DO $$
DECLARE
  event_id uuid;
  reclaimed boolean;
BEGIN
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'whatsapp.message.send_requested',
    1,
    'develop-hardening-ambiguous-whatsapp',
    jsonb_build_object('message_id', 'aaaaaaaa-0000-0000-0000-000000000001')
  ) RETURNING id INTO event_id;

  PERFORM id
  FROM public.claim_outbox_delivery_events('develop-hardening-worker-a', 20, 300)
  WHERE id = event_id;

  UPDATE public.outbox_events
  SET locked_until = timezone('utc', now()) - interval '1 second'
  WHERE id = event_id;

  SELECT EXISTS (
    SELECT 1
    FROM public.claim_outbox_delivery_events('develop-hardening-worker-b', 20, 300)
    WHERE id = event_id
  ) INTO reclaimed;

  IF reclaimed THEN
    RAISE EXCEPTION 'expired WhatsApp processing event was automatically reclaimed and could be delivered twice';
  END IF;
  IF (SELECT state FROM public.outbox_events WHERE id = event_id) <> 'needs_review' THEN
    RAISE EXCEPTION 'expired WhatsApp processing event must transition to needs_review';
  END IF;
  IF (SELECT last_error_code FROM public.outbox_events WHERE id = event_id) <> 'worker_lease_expired_ambiguous' THEN
    RAISE EXCEPTION 'ambiguous WhatsApp lease expiry must record a safe diagnostic code';
  END IF;
END;
$$;

SELECT 'develop security hardening regression tests passed' AS result;
