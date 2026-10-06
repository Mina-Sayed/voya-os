-- Direct PostgREST calls must satisfy the workspace AAL2 policy before any
-- booking/approval command or read implementation runs.
\set ON_ERROR_STOP on

CREATE FUNCTION pg_temp.assert_review_aal2_denial(p_statement text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_statement;
    RAISE EXCEPTION 'AAL2 regression accepted statement: %', p_statement;
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE '%MFA AAL2 is required for workspace data%' THEN
      RAISE;
    END IF;
  END;
END;
$$;
GRANT EXECUTE ON FUNCTION pg_temp.assert_review_aal2_denial(text) TO authenticated;

DO $$
DECLARE
  v_public_signatures text[] := ARRAY[
    'public.create_booking_draft(uuid,uuid,uuid,date,date,text,uuid)',
    'public.create_commercial_booking_draft(uuid,uuid,uuid,date,date,text,text,text,uuid)',
    'public.request_commercial_booking_approval(uuid,uuid,text,uuid)',
    'public.request_booking_amendment(uuid,uuid,uuid,uuid,date,date,text,text,text,text,uuid)',
    'public.execute_booking_amendment(uuid,uuid,uuid,text,uuid)',
    'public.decide_booking_approval(uuid,uuid,text,text,uuid)',
    'public.cancel_booking_draft(uuid,uuid,text,text,uuid)',
    'public.request_booking_cancellation(uuid,uuid,text,text,uuid)',
    'public.execute_booking_cancellation(uuid,uuid,text,uuid)',
    'public.record_booking_stay_event(uuid,uuid,text,text,text,uuid)',
    'public.list_booking_drafts(uuid)',
    'public.list_booking_work_queue(uuid)',
    'public.list_executable_booking_changes_v1(uuid)',
    'public.list_approval_requests(uuid,integer)',
    'public.list_approval_requests_v2(uuid,integer)'
  ];
  v_private_signatures text[] := ARRAY[
    'public.create_booking_draft_without_review_aal2(uuid,uuid,uuid,date,date,text,uuid)',
    'public.create_commercial_booking_draft_without_review_aal2(uuid,uuid,uuid,date,date,text,text,text,uuid)',
    'public.request_commercial_booking_approval_without_review_aal2(uuid,uuid,text,uuid)',
    'public.request_booking_amendment_without_review_aal2(uuid,uuid,uuid,uuid,date,date,text,text,text,text,uuid)',
    'public.execute_booking_amendment_without_review_aal2(uuid,uuid,uuid,text,uuid)',
    'public.decide_booking_approval_without_review_aal2(uuid,uuid,text,text,uuid)',
    'public.cancel_booking_draft_without_review_aal2(uuid,uuid,text,text,uuid)',
    'public.request_booking_cancellation_without_review_aal2(uuid,uuid,text,text,uuid)',
    'public.execute_booking_cancellation_without_review_aal2(uuid,uuid,text,uuid)',
    'public.record_booking_stay_event_without_review_aal2(uuid,uuid,text,text,text,uuid)',
    'public.list_booking_drafts_without_review_aal2(uuid)',
    'public.list_booking_work_queue_without_review_aal2(uuid)',
    'public.list_executable_booking_changes_v1_without_review_aal2(uuid)',
    'public.list_approval_requests_without_review_aal2(uuid,integer)',
    'public.list_approval_requests_v2_without_review_aal2(uuid,integer)'
  ];
  v_signature text;
  v_definition text;
BEGIN
  FOREACH v_signature IN ARRAY v_public_signatures LOOP
    IF to_regprocedure(v_signature) IS NULL
      OR NOT has_function_privilege('authenticated', v_signature, 'EXECUTE')
      OR has_function_privilege('anon', v_signature, 'EXECUTE')
      OR has_function_privilege('service_role', v_signature, 'EXECUTE') THEN
      RAISE EXCEPTION 'public booking/approval RPC grant matrix is invalid for %', v_signature;
    END IF;
    SELECT pg_get_functiondef(to_regprocedure(v_signature)) INTO v_definition;
    IF v_definition NOT LIKE '%require_workspace_aal2_v1%' THEN
      RAISE EXCEPTION 'public booking/approval RPC does not call the AAL2 guard: %', v_signature;
    END IF;
  END LOOP;

  FOREACH v_signature IN ARRAY v_private_signatures LOOP
    IF to_regprocedure(v_signature) IS NULL
      OR has_function_privilege('authenticated', v_signature, 'EXECUTE')
      OR has_function_privilege('anon', v_signature, 'EXECUTE')
      OR has_function_privilege('service_role', v_signature, 'EXECUTE') THEN
      RAISE EXCEPTION 'renamed booking/approval implementation is externally executable: %', v_signature;
    END IF;
  END LOOP;

  IF has_function_privilege('authenticated', 'public.create_booking_draft(uuid,uuid,uuid,date,date,text,uuid)', 'EXECUTE') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'legacy booking draft compatibility wrapper is missing its explicit authenticated grant';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', false);
DO $do$
DECLARE
  v_statement text;
  v_statements text[] := ARRAY[
    $$SELECT public.create_booking_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',DATE '2050-01-10',DATE '2050-01-11','aal2-draft-missing',NULL)$$,
    $$SELECT public.create_commercial_booking_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',DATE '2050-01-10',DATE '2050-01-11','100','EGP','aal2-commercial-missing',NULL)$$,
    $$SELECT public.request_commercial_booking_approval('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','aal2-approval-missing',NULL)$$,
    $$SELECT public.request_booking_amendment('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',DATE '2050-01-10',DATE '2050-01-11','100','EGP','reason','aal2-amend-missing',NULL)$$,
    $$SELECT public.execute_booking_amendment('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000004','aal2-amend-execute-missing',NULL)$$,
    $$SELECT public.decide_booking_approval('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000004','approved','reason',NULL)$$,
    $$SELECT public.cancel_booking_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','reason','aal2-cancel-missing',NULL)$$,
    $$SELECT public.request_booking_cancellation('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','reason','aal2-cancel-request-missing',NULL)$$,
    $$SELECT public.execute_booking_cancellation('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','aal2-cancel-execute-missing',NULL)$$,
    $$SELECT public.record_booking_stay_event('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','check_in',NULL,'aal2-stay-missing',NULL)$$,
    $$SELECT * FROM public.list_booking_drafts('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')$$,
    $$SELECT * FROM public.list_booking_work_queue('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')$$,
    $$SELECT * FROM public.list_executable_booking_changes_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')$$,
    $$SELECT * FROM public.list_approval_requests('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',50)$$,
    $$SELECT * FROM public.list_approval_requests_v2('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',50)$$
  ];
BEGIN
  FOREACH v_statement IN ARRAY v_statements LOOP
    PERFORM pg_temp.assert_review_aal2_denial(v_statement);
  END LOOP;
END;
$do$;

SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","aal":"aal1"}', false);
DO $do$
DECLARE
  v_statement text;
  v_statements text[] := ARRAY[
    $$SELECT public.create_booking_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',DATE '2050-01-10',DATE '2050-01-11','aal2-draft-aal1',NULL)$$,
    $$SELECT public.create_commercial_booking_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',DATE '2050-01-10',DATE '2050-01-11','100','EGP','aal2-commercial-aal1',NULL)$$,
    $$SELECT public.request_commercial_booking_approval('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','aal2-approval-aal1',NULL)$$,
    $$SELECT public.request_booking_amendment('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',DATE '2050-01-10',DATE '2050-01-11','100','EGP','reason','aal2-amend-aal1',NULL)$$,
    $$SELECT public.execute_booking_amendment('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000004','aal2-amend-execute-aal1',NULL)$$,
    $$SELECT public.decide_booking_approval('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000004','approved','reason',NULL)$$,
    $$SELECT public.cancel_booking_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','reason','aal2-cancel-aal1',NULL)$$,
    $$SELECT public.request_booking_cancellation('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','reason','aal2-cancel-request-aal1',NULL)$$,
    $$SELECT public.execute_booking_cancellation('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','aal2-cancel-execute-aal1',NULL)$$,
    $$SELECT public.record_booking_stay_event('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','aaaaaaaa-0000-0000-0000-000000000003','check_in',NULL,'aal2-stay-aal1',NULL)$$,
    $$SELECT * FROM public.list_booking_drafts('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')$$,
    $$SELECT * FROM public.list_booking_work_queue('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')$$,
    $$SELECT * FROM public.list_executable_booking_changes_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')$$,
    $$SELECT * FROM public.list_approval_requests('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',50)$$,
    $$SELECT * FROM public.list_approval_requests_v2('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',50)$$
  ];
BEGIN
  FOREACH v_statement IN ARRAY v_statements LOOP
    PERFORM pg_temp.assert_review_aal2_denial(v_statement);
  END LOOP;
END;
$do$;

SELECT set_config('request.jwt.claims', '', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);
SELECT count(*) FROM public.list_booking_drafts('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT count(*) FROM public.list_booking_work_queue('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT count(*) FROM public.list_executable_booking_changes_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT count(*) FROM public.list_approval_requests('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 50);
SELECT count(*) FROM public.list_approval_requests_v2('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 50);
RESET ROLE;

SELECT 'booking and approval AAL2 closure passed' AS result;
