-- Legacy booking write lifecycle RPCs are retained only as historical schema objects.
-- Browser roles must use the commercial V1 booking lifecycle instead.

DO $$
BEGIN
  IF to_regprocedure('extensions.digest(text,text)') IS NULL THEN
    RAISE EXCEPTION 'Supabase pgcrypto digest must be available in the extensions schema';
  END IF;
  IF pg_get_functiondef(to_regprocedure('public.decide_booking_approval(uuid,uuid,text,text,uuid)'))
     LIKE '%v_approver_role%' THEN
    RAISE EXCEPTION 'booking approval function must not retain unused approver role state';
  END IF;
  IF has_table_privilege('authenticated', 'public.booking_stay_events', 'INSERT')
    OR has_table_privilege('authenticated', 'public.bookings', 'UPDATE') THEN
    RAISE EXCEPTION 'browser role must use booking lifecycle RPCs';
  END IF;
  IF has_function_privilege('authenticated', 'public.create_booking_draft(uuid,uuid,uuid,date,date,text,uuid)', 'EXECUTE'
    OR has_function_privilege('authenticated', 'public.request_booking_approval(uuid,uuid,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.confirm_booking(uuid,uuid,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.record_booking_stay_event(uuid,uuid,text,text,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must not execute legacy booking write lifecycle RPCs';
  END IF;
  IF has_function_privilege('anon', 'public.create_booking_draft(uuid,uuid,uuid,date,date,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.request_booking_approval(uuid,uuid,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.confirm_booking(uuid,uuid,text,uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.record_booking_stay_event(uuid,uuid,text,text,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute legacy booking write lifecycle RPCs';
  END IF;
END;
$$;

-- Keep the manager fixture used by later commercial-booking, approval,
-- notification, WhatsApp, and AI database integration tests.
INSERT INTO auth.users (id)
VALUES ('55555555-5555-5555-5555-555555555555')
ON CONFLICT DO NOTHING;
INSERT INTO public.profiles (id, display_name)
VALUES ('55555555-5555-5555-5555-55555555555', 'Booking manager')
ON CONFLICT DO NOTHING;
INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '55555555-5555-5555-5555-555555555555', 'manager', 'active')
ON CONFLICT DO NOTHING;

-- Read access remains independently permissioned; a suspended member must not
-- regain booking visibility merely because legacy write functions still exist.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_booking_work_queue('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'suspended viewer must not read booking work queue';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'legacy booking lifecycle RPC retirement tests passed' AS result;
