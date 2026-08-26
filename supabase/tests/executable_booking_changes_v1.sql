-- Executable booking change projection contract.
\set ON_ERROR_STOP on

DO $$
DECLARE
  definition text;
BEGIN
  IF to_regprocedure('public.list_executable_booking_changes_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'executable booking change projection is missing';
  END IF;
  IF has_function_privilege('anon', 'public.list_executable_booking_changes_v1(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute executable booking change projection';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.list_executable_booking_changes_v1(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated role must be able to call the guarded projection';
  END IF;

  SELECT pg_get_functiondef('public.list_executable_booking_changes_v1(uuid)'::regprocedure)
  INTO definition;

  IF definition NOT LIKE '%request.status = ''approved''%'
    OR definition NOT LIKE '%request.expires_at >%'
    OR definition NOT LIKE '%request.requester_membership_id <> v_actor%'
    OR definition NOT LIKE '%booking.status = ''pending_approval''%'
    OR definition NOT LIKE '%booking.status = ''confirmed''%'
    OR definition NOT LIKE '%confirmation_property.status = ''active''%'
    OR definition NOT LIKE '%amendment_property.status = ''active''%'
    OR definition NOT LIKE '%amendment_client.archived_at IS NULL%' THEN
    RAISE EXCEPTION 'executable booking change projection is missing required state boundaries';
  END IF;
END;
$$;

SELECT 'executable booking change projection tests passed' AS result;
