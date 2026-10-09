-- Preserve immutable PR77 update results when the PR79 authorization wrapper
-- sees an older key for the first time. Current mutable lead fields cannot
-- disprove the original request once a later, valid update has committed.
DO $migration$
DECLARE
  v_definition text;
  v_previous text := E'  IF FOUND THEN\n    IF v_legacy.resource_id <> p_lead_id';
BEGIN
  SELECT pg_get_functiondef('public.update_lead_v1(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid)'::regprocedure)
  INTO v_definition;
  IF strpos(v_definition, 'v_legacy.payload_hash IS NOT NULL') > 0 THEN RETURN; END IF;
  IF strpos(v_definition, v_previous) = 0
    OR strpos(v_definition, 'lead reassignment is not permitted') = 0
    OR strpos(pg_get_functiondef('public.update_lead_v1_without_workspace_aal2(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid)'::regprocedure),
      'crm_update_lead_payload_hash_v1') = 0 THEN
    RAISE EXCEPTION 'CRM integration replay implementations changed unexpectedly';
  END IF;
  EXECUTE replace(v_definition, v_previous, $replacement$
  IF FOUND AND v_legacy.payload_hash IS NOT NULL THEN
    -- The underlying PR77 command checks current assignment and the immutable
    -- canonical payload, without comparing against later mutable lead facts.
    v_result := public.update_lead_v1_without_review_guards(
      p_organization_id, p_lead_id, p_name, p_phone, p_whatsapp, p_email, p_source,
      p_status, p_assigned_membership_id, p_requested_area, p_check_in, p_check_out,
      p_guests, p_bedrooms, p_budget_text, p_notes, p_next_follow_up_at,
      p_expected_version, p_idempotency_key, p_request_id
    );
    INSERT INTO public.review_crm_request_bindings (
      organization_id, command_name, idempotency_key, resource_id, request_hash, result
    ) VALUES (
      p_organization_id, 'lead.update', btrim(p_idempotency_key), p_lead_id, v_hash, to_jsonb(v_result)
    );
    RETURN v_result;
  ELSIF FOUND THEN
    IF v_legacy.resource_id <> p_lead_id$replacement$);
END;
$migration$;
REVOKE ALL ON FUNCTION public.update_lead_v1(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid)
  FROM PUBLIC, anon, service_role, voya_outbox_worker;
GRANT EXECUTE ON FUNCTION public.update_lead_v1(uuid,uuid,text,text,text,text,text,text,uuid,text,date,date,integer,integer,text,text,timestamptz,integer,text,uuid)
  TO authenticated;

-- The ordering wrapper from PR77 supersedes PR76's outer sanitizer. Keep its
-- ordering/kill-switch checks and restore sanitized proposal state before it
-- calls the PR79-hardened legacy CRM projection.
DO $migration$
DECLARE
  v_definition text;
  v_previous text := E'    p_conversation_type,\n    p_structured_state,\n    p_reply,';
  v_marker text := '  -- Lock the same conversation row that the implementation locks below.';
BEGIN
  SELECT pg_get_functiondef('public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)'::regprocedure)
  INTO v_definition;
  IF strpos(v_definition, 'v_safe_state jsonb') > 0 THEN RETURN; END IF;
  IF strpos(v_definition, v_previous) = 0 OR strpos(v_definition, v_marker) = 0
    OR strpos(v_definition, 'last_ai_processed_message_id') = 0 THEN
    RAISE EXCEPTION 'WhatsApp ordering wrapper changed unexpectedly during integration';
  END IF;
  v_definition := replace(v_definition, E'DECLARE\n', E'DECLARE\n  v_safe_state jsonb := p_structured_state;\n  v_lead_state jsonb;\n');
  v_definition := replace(v_definition, v_marker, $sanitizer$
  IF jsonb_typeof(v_safe_state) = 'object' AND jsonb_typeof(v_safe_state -> 'lead') = 'object' THEN
    v_lead_state := v_safe_state -> 'lead';
    IF position('@' IN coalesce(v_lead_state ->> 'phone', '')) > 0
      OR lower(left(btrim(v_lead_state ->> 'phone'), 320)) LIKE 'openwa-jid:%' THEN
      v_lead_state := jsonb_set(v_lead_state, '{phone}', 'null'::jsonb, true);
    END IF;
    IF position('@' IN coalesce(v_lead_state ->> 'whatsapp', '')) > 0
      OR lower(left(btrim(v_lead_state ->> 'whatsapp'), 320)) LIKE 'openwa-jid:%' THEN
      v_lead_state := jsonb_set(v_lead_state, '{whatsapp}', 'null'::jsonb, true);
    END IF;
    v_safe_state := jsonb_set(v_safe_state, '{lead}', v_lead_state, true);
  END IF;
$sanitizer$ || v_marker);
  EXECUTE replace(v_definition, v_previous, E'    p_conversation_type,\n    v_safe_state,\n    p_reply,');
END;
$migration$;
REVOKE ALL ON FUNCTION public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)
  TO service_role, voya_outbox_worker;
