-- Resume partial WhatsApp property confirmations with the original accepted
-- payload and command idempotency keys. Older partial results only persisted
-- owner/property IDs, so recover the already-created ownership period from
-- its tenant, parent IDs, and exact accepted date range.

CREATE OR REPLACE FUNCTION public.claim_whatsapp_property_confirmation_v1_without_workspace_aal2(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_confirmation_payload jsonb,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS TABLE (
  outcome text,
  confirmation_token uuid,
  conversation_version integer,
  confirmation_payload jsonb,
  confirmation_result jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_conversation public.whatsapp_conversations%ROWTYPE;
  v_token uuid;
  v_attempt_key text;
  v_result jsonb;
  v_command_keys jsonb;
  v_image_keys jsonb;
  v_ownership_period_id uuid;
BEGIN
  IF p_conversation_id IS NULL OR p_confirmation_payload IS NULL
    OR jsonb_typeof(p_confirmation_payload) <> 'object'
    OR char_length(p_confirmation_payload::text) > 30000
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'WhatsApp property confirmation input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'WhatsApp property confirmation is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT conversation.* INTO v_conversation
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.organization_id = p_organization_id
    AND conversation.id = p_conversation_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'WhatsApp conversation was not found' USING ERRCODE = '23503'; END IF;
  IF v_conversation.conversation_type <> 'owner_onboarding' THEN
    RAISE EXCEPTION 'conversation is not an owner draft' USING ERRCODE = '22023';
  END IF;

  IF v_conversation.confirmation_status = 'partially_applied' THEN
    IF v_conversation.ai_state_version <> p_expected_version THEN
      RAISE EXCEPTION 'WhatsApp property draft version is stale' USING ERRCODE = '40001';
    END IF;

    v_result := coalesce(v_conversation.confirmation_result, '{}'::jsonb);
    v_attempt_key := coalesce(
      nullif(v_result ->> 'attemptKey', ''),
      'whatsapp:' || p_conversation_id::text || ':' || coalesce(v_conversation.confirmation_key, btrim(p_idempotency_key))
    );
    v_image_keys := CASE
      WHEN jsonb_typeof(v_result #> '{commandKeys,images}') = 'object' THEN v_result #> '{commandKeys,images}'
      ELSE '{}'::jsonb
    END;
    v_command_keys := jsonb_build_object(
      'owner', coalesce(nullif(v_result #>> '{commandKeys,owner}', ''), v_attempt_key || ':owner'),
      'property', coalesce(nullif(v_result #>> '{commandKeys,property}', ''), v_attempt_key || ':property'),
      'ownership', coalesce(nullif(v_result #>> '{commandKeys,ownership}', ''), v_attempt_key || ':ownership'),
      'images', v_image_keys
    );
    v_result := v_result || jsonb_build_object('attemptKey', v_attempt_key, 'commandKeys', v_command_keys);

    IF v_result ->> 'ownershipPeriodId' IS NULL
      AND v_result ->> 'propertyOwnerId' IS NOT NULL
      AND v_result ->> 'propertyId' IS NOT NULL
      AND v_conversation.confirmation_payload ? 'ownershipStartDate'
      AND v_conversation.confirmation_payload ? 'ownershipEndDate' THEN
      SELECT period.id INTO v_ownership_period_id
      FROM public.property_ownership_periods AS period
      WHERE period.organization_id = p_organization_id
        AND period.property_id::text = v_result ->> 'propertyId'
        AND period.property_owner_id::text = v_result ->> 'propertyOwnerId'
        AND pg_catalog.to_char(period.start_date, 'YYYY-MM-DD') = v_conversation.confirmation_payload ->> 'ownershipStartDate'
        AND pg_catalog.to_char(period.end_date, 'YYYY-MM-DD') = v_conversation.confirmation_payload ->> 'ownershipEndDate'
      ORDER BY period.created_at DESC, period.id DESC
      LIMIT 1;
      IF v_ownership_period_id IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('ownershipPeriodId', v_ownership_period_id);
      END IF;
    END IF;

    v_token := extensions.gen_random_uuid();
    UPDATE public.whatsapp_conversations
    SET confirmation_status = 'claimed',
        confirmation_token = v_token,
        confirmation_claimed_at = timezone('utc', now()),
        confirmation_result = v_result,
        ai_state_version = ai_state_version + 1
    WHERE organization_id = p_organization_id AND id = p_conversation_id;
    INSERT INTO public.audit_events (
      organization_id, actor_type, actor_membership_id, action, resource_type,
      resource_id, outcome, request_id, after_delta
    ) VALUES (
      p_organization_id, 'user', v_actor, 'whatsapp.property_confirmation.resumed',
      'whatsapp_conversation', p_conversation_id, 'success', p_request_id,
      jsonb_build_object('confirmation_key', v_conversation.confirmation_key)
    );
    RETURN QUERY SELECT 'claimed', v_token, v_conversation.ai_state_version + 1,
      v_conversation.confirmation_payload, v_result;
    RETURN;
  END IF;

  IF v_conversation.confirmation_key = btrim(p_idempotency_key)
    AND v_conversation.confirmation_status IN ('confirmed', 'needs_review') THEN
    RETURN QUERY SELECT v_conversation.confirmation_status, v_conversation.confirmation_token,
      v_conversation.ai_state_version, v_conversation.confirmation_payload, v_conversation.confirmation_result;
    RETURN;
  END IF;
  IF v_conversation.confirmation_status = 'claimed'
    AND v_conversation.confirmation_key = btrim(p_idempotency_key)
    AND v_conversation.confirmation_token IS NOT NULL THEN
    RETURN QUERY SELECT 'claimed', v_conversation.confirmation_token,
      v_conversation.ai_state_version, v_conversation.confirmation_payload, v_conversation.confirmation_result;
    RETURN;
  END IF;
  IF v_conversation.confirmation_status = 'claimed'
    AND v_conversation.confirmation_claimed_at > timezone('utc', now()) - interval '30 minutes' THEN
    RETURN QUERY SELECT 'in_progress', v_conversation.confirmation_token,
      v_conversation.ai_state_version, v_conversation.confirmation_payload, v_conversation.confirmation_result;
    RETURN;
  END IF;
  IF p_confirmation_payload = '{}'::jsonb THEN
    RAISE EXCEPTION 'WhatsApp property confirmation payload is required' USING ERRCODE = '22023';
  END IF;
  IF v_conversation.ai_state_version <> p_expected_version THEN
    RAISE EXCEPTION 'WhatsApp property draft version is stale' USING ERRCODE = '40001';
  END IF;

  v_token := extensions.gen_random_uuid();
  UPDATE public.whatsapp_conversations
  SET confirmation_status = 'claimed',
      confirmation_key = btrim(p_idempotency_key),
      confirmation_token = v_token,
      confirmation_claimed_at = timezone('utc', now()),
      confirmation_payload = p_confirmation_payload,
      ai_state_version = ai_state_version + 1
  WHERE organization_id = p_organization_id AND id = p_conversation_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'whatsapp.property_confirmation.claimed',
    'whatsapp_conversation', p_conversation_id, 'success', p_request_id,
    jsonb_build_object('confirmation_key', btrim(p_idempotency_key))
  );
  RETURN QUERY SELECT 'claimed', v_token, v_conversation.ai_state_version + 1,
    p_confirmation_payload, v_conversation.confirmation_result;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_whatsapp_property_confirmation_v1_without_workspace_aal2(
  uuid, uuid, jsonb, integer, text, uuid
) FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker;
