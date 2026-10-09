-- Recover committed subcommands before accepting amendments. Only pending
-- owner/property/ownership sections can change; command keys never change.
-- The public AAL2 wrapper is retained and the implementation stays private.

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
  v_owner public.property_owners%ROWTYPE;
  v_property public.properties%ROWTYPE;
  v_period public.property_ownership_periods%ROWTYPE;
  v_payload jsonb;
  v_saved_payload jsonb;
  v_record_payload jsonb;
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

  -- Row lock serializes claim decisions. Never give a second executor the
  -- current token, even for the same browser key. Expired executions retain
  -- their subcommand keys so a late commit cannot create duplicate inventory.
  IF v_conversation.confirmation_status = 'claimed'
    AND v_conversation.confirmation_claimed_at > timezone('utc', now()) - interval '30 minutes' THEN
    RETURN QUERY SELECT 'in_progress', NULL::uuid, v_conversation.ai_state_version,
      v_conversation.confirmation_payload, v_conversation.confirmation_result;
    RETURN;
  END IF;
  IF v_conversation.confirmation_status IN ('confirmed', 'needs_review') THEN
    RETURN QUERY SELECT v_conversation.confirmation_status, NULL::uuid,
      v_conversation.ai_state_version, v_conversation.confirmation_payload, v_conversation.confirmation_result;
    RETURN;
  END IF;

  IF v_conversation.confirmation_status IN ('partially_applied', 'claimed') THEN
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

    v_saved_payload := v_conversation.confirmation_payload;
    IF v_saved_payload IS NULL OR jsonb_typeof(v_saved_payload) <> 'object' THEN
      RAISE EXCEPTION 'stored confirmation payload is invalid' USING ERRCODE = '22023';
    END IF;
    v_payload := CASE WHEN p_confirmation_payload = '{}'::jsonb OR v_conversation.confirmation_status = 'claimed'
      THEN v_saved_payload ELSE p_confirmation_payload END;

    -- Resolve original command keys before considering changes: a timeout can
    -- hide a committed command from the last recorded progress result.
    SELECT owner_record.* INTO v_owner FROM public.property_owners AS owner_record
    WHERE owner_record.organization_id = p_organization_id
      AND owner_record.idempotency_key = v_command_keys ->> 'owner';
    IF v_owner.id IS NULL AND v_result ->> 'propertyOwnerId' IS NOT NULL THEN
      SELECT owner_record.* INTO v_owner FROM public.property_owners AS owner_record
      WHERE owner_record.organization_id = p_organization_id
        AND owner_record.id::text = v_result ->> 'propertyOwnerId';
      IF NOT FOUND THEN RAISE EXCEPTION 'stored owner result is invalid' USING ERRCODE = '23503'; END IF;
    END IF;
    IF v_owner.id IS NOT NULL THEN
      IF v_owner.status <> 'active' OR (v_result ->> 'propertyOwnerId' IS NOT NULL
        AND v_result ->> 'propertyOwnerId' <> v_owner.id::text) THEN
        RAISE EXCEPTION 'stored owner result is unavailable' USING ERRCODE = '23503';
      END IF;
      -- A delayed original command may commit after a partial amendment.
      -- If its record differs from the currently accepted section, require
      -- review rather than silently reporting the amended fields as applied.
      v_record_payload := jsonb_build_object(
        'displayName', v_owner.display_name,
        'phone', v_owner.phone,
        'whatsapp', v_owner.whatsapp,
        'email', v_owner.email,
        'preferredContactMethod', v_owner.preferred_contact_method,
        'notes', v_owner.notes);
      IF EXISTS (SELECT 1 FROM jsonb_each(v_saved_payload -> 'owner') AS field
        WHERE v_record_payload -> field.key IS DISTINCT FROM CASE
          WHEN field.key = 'email' THEN coalesce(to_jsonb(nullif(lower(btrim(field.value #>> '{}')), '')), 'null'::jsonb)
          WHEN field.key = 'displayName' THEN coalesce(to_jsonb(btrim(field.value #>> '{}')), 'null'::jsonb)
          WHEN field.key IN ('phone', 'whatsapp', 'notes') THEN coalesce(to_jsonb(nullif(btrim(field.value #>> '{}'), '')), 'null'::jsonb)
          ELSE field.value END) THEN
        RAISE EXCEPTION 'committed owner differs from accepted payload' USING ERRCODE = '23505';
      END IF;
      v_result := v_result || jsonb_build_object('propertyOwnerId', v_owner.id);
      v_payload := jsonb_set(v_payload, '{owner}', v_saved_payload -> 'owner');
    END IF;

    SELECT property_record.* INTO v_property FROM public.properties AS property_record
    WHERE property_record.organization_id = p_organization_id
      AND property_record.idempotency_key = v_command_keys ->> 'property';
    IF v_property.id IS NULL AND v_result ->> 'propertyId' IS NOT NULL THEN
      SELECT property_record.* INTO v_property FROM public.properties AS property_record
      WHERE property_record.organization_id = p_organization_id
        AND property_record.id::text = v_result ->> 'propertyId';
      IF NOT FOUND THEN RAISE EXCEPTION 'stored property result is invalid' USING ERRCODE = '23503'; END IF;
    END IF;
    IF v_property.id IS NOT NULL THEN
      IF v_property.status = 'archived' OR (v_result ->> 'propertyId' IS NOT NULL
        AND v_result ->> 'propertyId' <> v_property.id::text) THEN
        RAISE EXCEPTION 'stored property result is unavailable' USING ERRCODE = '23503';
      END IF;
      -- A delayed original command may commit after a partial amendment.
      -- If its record differs from the currently accepted section, require
      -- review rather than silently reporting the amended fields as applied.
      v_record_payload := jsonb_build_object(
        'code', v_property.code,
        'name', v_property.name,
        'timezone', v_property.timezone,
        'address', v_property.address,
        'city', v_property.city,
        'unitLabel', v_property.unit_label,
        'bedrooms', v_property.bedrooms,
        'maxGuests', v_property.max_guests,
        'operationalNotes', v_property.operational_notes,
        'bathrooms', v_property.bathrooms,
        'areaSqm', v_property.area_sqm,
        'floor', v_property.floor,
        'furnished', v_property.furnished,
        'district', v_property.district,
        'rentDaily', v_property.rent_daily,
        'rentWeekly', v_property.rent_weekly,
        'rentMonthly', v_property.rent_monthly,
        'dailyPrice', v_property.daily_price,
        'weeklyPrice', v_property.weekly_price,
        'monthlyPrice', v_property.monthly_price,
        'currency', v_property.currency,
        'amenities', v_property.amenities,
        'minimumStayNights', v_property.minimum_stay_nights,
        'marketingDescription', v_property.marketing_description);
      IF EXISTS (SELECT 1 FROM jsonb_each(v_saved_payload -> 'property') AS field
        WHERE v_record_payload -> field.key IS DISTINCT FROM CASE
          WHEN field.key IN ('code', 'name', 'timezone') THEN coalesce(to_jsonb(btrim(field.value #>> '{}')), 'null'::jsonb)
          WHEN field.key IN ('address', 'city', 'unitLabel', 'operationalNotes', 'floor', 'district', 'marketingDescription')
            THEN coalesce(to_jsonb(nullif(btrim(field.value #>> '{}'), '')), 'null'::jsonb)
          WHEN field.key IN ('rentDaily', 'rentWeekly', 'rentMonthly') THEN to_jsonb(coalesce((field.value #>> '{}')::boolean, false))
          ELSE field.value END) THEN
        RAISE EXCEPTION 'committed property differs from accepted payload' USING ERRCODE = '23505';
      END IF;
      v_result := v_result || jsonb_build_object('propertyId', v_property.id);
      v_payload := jsonb_set(v_payload, '{property}', v_saved_payload -> 'property');
    END IF;

    SELECT period.* INTO v_period FROM public.property_ownership_periods AS period
    WHERE period.organization_id = p_organization_id
      AND period.idempotency_key = v_command_keys ->> 'ownership';
    IF v_period.id IS NULL AND v_result ->> 'ownershipPeriodId' IS NOT NULL THEN
      SELECT period.* INTO v_period FROM public.property_ownership_periods AS period
      WHERE period.organization_id = p_organization_id
        AND period.id::text = v_result ->> 'ownershipPeriodId';
      IF NOT FOUND THEN RAISE EXCEPTION 'stored ownership result is invalid' USING ERRCODE = '23503'; END IF;
    END IF;
    IF v_period.id IS NULL AND v_owner.id IS NOT NULL AND v_property.id IS NOT NULL THEN
      -- Legacy progress did not store the ownership result. Recover only the
      -- original accepted relationship, never a corrected date range.
      SELECT period.* INTO v_period FROM public.property_ownership_periods AS period
      WHERE period.organization_id = p_organization_id
        AND period.property_id = v_property.id AND period.property_owner_id = v_owner.id
        AND to_char(period.start_date, 'YYYY-MM-DD') = v_saved_payload ->> 'ownershipStartDate'
        AND to_char(period.end_date, 'YYYY-MM-DD') = v_saved_payload ->> 'ownershipEndDate';
    END IF;
    IF v_period.id IS NOT NULL THEN
      IF (v_result ->> 'ownershipPeriodId' IS NOT NULL AND v_result ->> 'ownershipPeriodId' <> v_period.id::text)
        OR v_period.property_id IS DISTINCT FROM v_property.id
        OR v_period.property_owner_id IS DISTINCT FROM v_owner.id
        OR to_char(v_period.start_date, 'YYYY-MM-DD') IS DISTINCT FROM v_saved_payload ->> 'ownershipStartDate'
        OR to_char(v_period.end_date, 'YYYY-MM-DD') IS DISTINCT FROM v_saved_payload ->> 'ownershipEndDate' THEN
        RAISE EXCEPTION 'stored ownership parents are invalid' USING ERRCODE = '23503';
      END IF;
      v_result := v_result || jsonb_build_object('ownershipPeriodId', v_period.id);
      v_payload := jsonb_set(jsonb_set(v_payload, '{ownershipStartDate}', v_saved_payload -> 'ownershipStartDate'),
        '{ownershipEndDate}', v_saved_payload -> 'ownershipEndDate');
    END IF;
    IF v_payload IS NULL THEN
      RAISE EXCEPTION 'stored confirmation sections are invalid' USING ERRCODE = '22023';
    END IF;

    v_token := extensions.gen_random_uuid();
    UPDATE public.whatsapp_conversations
    SET confirmation_status = 'claimed',
        confirmation_token = v_token,
        confirmation_claimed_at = timezone('utc', now()),
        confirmation_result = v_result,
        confirmation_payload = v_payload,
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
      v_payload, v_result;
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
