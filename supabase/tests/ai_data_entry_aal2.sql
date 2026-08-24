-- Regression proof: every authenticated AI data-entry user RPC must reject
-- password-only (aal1) sessions at the database boundary, not only in the UI.

DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.create_ai_data_entry_draft_v1_unchecked(uuid,text,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.register_ai_data_entry_input_v1_unchecked(uuid,uuid,text,text,bigint,text,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.submit_ai_data_entry_draft_v1_unchecked(uuid,uuid,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.list_ai_data_entry_drafts_v1_unchecked(uuid,integer)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.get_ai_data_entry_draft_v1_unchecked(uuid,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.list_ai_data_entry_inputs_v1_unchecked(uuid,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.claim_ai_data_entry_confirmation_v3_unchecked(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.reject_ai_data_entry_draft_v1_unchecked(uuid,uuid,integer,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must not execute unchecked AI data-entry implementations';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal1"}',
  false
);
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

DO $$
DECLARE
  v_draft_id uuid := 'aaaaaaaa-0000-0000-0000-00000000a199'::uuid;
BEGIN
  BEGIN
    PERFORM public.create_ai_data_entry_draft_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aal1 must not create a draft',
      'aal1-draft-denied',
      'aaaaaaaa-0000-0000-0000-00000000a101'
    );
    RAISE EXCEPTION 'aal1 create_ai_data_entry_draft_v1 must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM public.register_ai_data_entry_input_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      v_draft_id,
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/aaaaaaaa-0000-0000-0000-00000000a199/aaaaaaaa-0000-0000-0000-00000000a198.png',
      'image/png', 16, NULL, 'aal1-input-denied', NULL
    );
    RAISE EXCEPTION 'aal1 register_ai_data_entry_input_v1 must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM public.submit_ai_data_entry_draft_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_draft_id,
      'aal1-submit-denied', NULL
    );
    RAISE EXCEPTION 'aal1 submit_ai_data_entry_draft_v1 must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM * FROM public.get_ai_data_entry_draft_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_draft_id
    );
    RAISE EXCEPTION 'aal1 get_ai_data_entry_draft_v1 must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM * FROM public.list_ai_data_entry_drafts_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    );
    RAISE EXCEPTION 'aal1 list_ai_data_entry_drafts_v1 must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM * FROM public.list_ai_data_entry_inputs_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_draft_id
    );
    RAISE EXCEPTION 'aal1 list_ai_data_entry_inputs_v1 must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM * FROM public.claim_ai_data_entry_confirmation_v3(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_draft_id,
      '{"clients":[],"properties":[],"unresolved":[],"warnings":[]}'::jsonb,
      ARRAY[]::integer[], ARRAY[]::integer[], 1,
      'aal1-confirm-denied', NULL
    );
    RAISE EXCEPTION 'aal1 claim_ai_data_entry_confirmation_v3 must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM public.reject_ai_data_entry_draft_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_draft_id,
      1, 'aal1-reject-denied', NULL
    );
    RAISE EXCEPTION 'aal1 reject_ai_data_entry_draft_v1 must be denied';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;

-- AAL2 remains usable for a legitimate member.
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aal":"aal2"}',
  false
);
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_ai_data_entry_draft_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aal2 draft succeeds',
  'aal2-draft-allowed',
  'aaaaaaaa-0000-0000-0000-00000000a102'
) AS aal2_draft_id \gset

SELECT CASE WHEN :'aal2_draft_id'::uuid IS NOT NULL THEN 1 ELSE 1 / 0 END;

RESET ROLE;
