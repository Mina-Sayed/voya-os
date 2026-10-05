-- A failed property insert can be corrected while already-applied inventory
-- stays bound to the original confirmation and command keys. Keep the existing
-- AAL2 public wrapper and isolate the previous claim implementation.
ALTER FUNCTION public.claim_whatsapp_property_confirmation_v1_without_workspace_aal2(
  uuid, uuid, jsonb, integer, text, uuid
) RENAME TO claim_whatsapp_property_confirmation_v1_before_correction;
REVOKE ALL ON FUNCTION public.claim_whatsapp_property_confirmation_v1_before_correction(
  uuid, uuid, jsonb, integer, text, uuid
) FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker;

CREATE OR REPLACE FUNCTION public.claim_whatsapp_property_confirmation_v1_without_workspace_aal2(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_confirmation_payload jsonb,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS TABLE (
  outcome text, confirmation_token uuid, conversation_version integer,
  confirmation_payload jsonb, confirmation_result jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_conversation public.whatsapp_conversations%ROWTYPE;
  v_result jsonb;
  v_payload jsonb;
  v_property_key text;
  v_property_id uuid;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
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

  IF FOUND AND v_conversation.confirmation_status = 'partially_applied' THEN
    IF p_expected_version IS DISTINCT FROM v_conversation.ai_state_version THEN
      RAISE EXCEPTION 'WhatsApp property draft version is stale' USING ERRCODE = '40001';
    END IF;
    v_result := coalesce(v_conversation.confirmation_result, '{}'::jsonb);
    v_payload := v_conversation.confirmation_payload;
    v_property_key := coalesce(
      nullif(v_result #>> '{commandKeys,property}', ''),
      coalesce(nullif(v_result ->> 'attemptKey', ''),
        'whatsapp:' || p_conversation_id::text || ':' ||
          coalesce(v_conversation.confirmation_key, btrim(p_idempotency_key))) || ':property'
    );

    -- Missing progress is not proof that the command did not commit. Resolve
    -- its tenant-scoped key before accepting any correction. Retain that key:
    -- the property creation guards below also hold this conversation lock and
    -- reject superseded facts from an older in-flight Action.
    IF nullif(v_result ->> 'propertyId', '') IS NULL THEN
      SELECT property.id INTO v_property_id
      FROM public.properties AS property
      WHERE property.organization_id = p_organization_id
        AND property.idempotency_key = v_property_key;
      IF FOUND THEN
        v_result := v_result || jsonb_build_object('propertyId', v_property_id);
      ELSIF p_confirmation_payload IS NOT NULL AND p_confirmation_payload <> '{}'::jsonb THEN
        IF jsonb_typeof(p_confirmation_payload -> 'property') IS DISTINCT FROM 'object' THEN
          RAISE EXCEPTION 'WhatsApp property correction payload is invalid' USING ERRCODE = '22023';
        END IF;
        IF v_payload -> 'property' IS DISTINCT FROM p_confirmation_payload -> 'property' THEN
          -- Owner facts and ownership dates remain the accepted snapshot.
          -- Only the not-yet-created property's facts are editable here.
          v_payload := jsonb_set(v_payload, '{property}', p_confirmation_payload -> 'property');
          INSERT INTO public.audit_events (
            organization_id, actor_type, actor_membership_id, action, resource_type,
            resource_id, outcome, request_id, after_delta
          ) VALUES (
            p_organization_id, 'user', v_actor, 'whatsapp.property_confirmation.corrected',
            'whatsapp_conversation', p_conversation_id, 'success', p_request_id,
            jsonb_build_object('corrected_section', 'property')
          );
        END IF;
      END IF;
    END IF;

    UPDATE public.whatsapp_conversations
    SET confirmation_payload = v_payload, confirmation_result = v_result
    WHERE organization_id = p_organization_id AND id = p_conversation_id;
  END IF;

  RETURN QUERY SELECT * FROM public.claim_whatsapp_property_confirmation_v1_before_correction(
    p_organization_id, p_conversation_id, p_confirmation_payload,
    p_expected_version, p_idempotency_key, p_request_id
  );
END;
$$;
REVOKE ALL ON FUNCTION public.claim_whatsapp_property_confirmation_v1_without_workspace_aal2(
  uuid, uuid, jsonb, integer, text, uuid
) FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker;

-- Serialize each WhatsApp property insert with confirmation corrections. A
-- previously claimed Action may still be in flight after another attempt
-- finalized partial progress; retaining its command key prevents duplicates,
-- while this guard rejects its superseded property facts before they commit.
DO $migration$
DECLARE
  v_signature text;
  v_definition text;
  v_header text;
  v_types text;
  v_arguments text;
  v_property_arguments text;
  v_oid oid;
  v_header_end integer;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'public.create_property_v1(uuid,text,text,text,text,text,text,integer,integer,text,text,uuid)',
    'public.create_property_v1(uuid,text,text,text,text,text,text,integer,integer,text,integer,numeric,text,boolean,text,boolean,boolean,boolean,numeric,numeric,numeric,text,text[],integer,text,text,uuid)'
  ] LOOP
    v_oid := to_regprocedure(v_signature);
    IF v_oid IS NULL THEN RAISE EXCEPTION 'property confirmation signature missing: %', v_signature; END IF;
    v_definition := pg_get_functiondef(v_oid);
    v_header_end := strpos(v_definition, 'AS $function$');
    IF v_header_end = 0 THEN RAISE EXCEPTION 'unsupported property function definition'; END IF;
    v_header := substring(v_definition FROM 1 FOR v_header_end + length('AS $function$') - 1);
    SELECT string_agg(format_type(argument_type, NULL), ', ' ORDER BY position),
           string_agg(format('$%s', position), ', ' ORDER BY position)
    INTO v_types, v_arguments
    FROM unnest((SELECT proargtypes FROM pg_proc WHERE oid = v_oid))
      WITH ORDINALITY AS argument(argument_type, position);

    v_property_arguments := '''code'', p_code, ''name'', p_name, ''timezone'', p_timezone,
      ''address'', p_address, ''city'', p_city, ''unitLabel'', p_unit_label,
      ''bedrooms'', p_bedrooms, ''maxGuests'', p_max_guests, ''operationalNotes'', p_operational_notes';
    IF (SELECT pronargs FROM pg_proc WHERE oid = v_oid) = 27 THEN
      v_property_arguments := v_property_arguments || ',
        ''bathrooms'', p_bathrooms, ''areaSqm'', p_area_sqm, ''floor'', p_floor,
        ''furnished'', p_furnished, ''district'', p_district,
        ''rentDaily'', p_rent_daily, ''rentWeekly'', p_rent_weekly, ''rentMonthly'', p_rent_monthly,
        ''dailyPrice'', p_daily_price, ''weeklyPrice'', p_weekly_price, ''monthlyPrice'', p_monthly_price,
        ''currency'', p_currency, ''amenities'', p_amenities,
        ''minimumStayNights'', p_minimum_stay_nights, ''marketingDescription'', p_marketing_description';
    END IF;

    EXECUTE format('ALTER FUNCTION public.create_property_v1(%s) RENAME TO create_property_v1_before_whatsapp_correction', v_types);
    EXECUTE format('REVOKE ALL ON FUNCTION public.create_property_v1_before_whatsapp_correction(%s) FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker', v_types);
    EXECUTE v_header || format($body$
DECLARE v_accepted jsonb; v_submitted jsonb;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_idempotency_key LIKE 'whatsapp:%%' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.organization_memberships AS membership
      WHERE membership.organization_id = p_organization_id
        AND membership.user_id = auth.uid() AND membership.status = 'active'
        AND membership.role IN ('owner', 'manager', 'operations')
    ) THEN
      RAISE EXCEPTION 'WhatsApp property creation is not permitted' USING ERRCODE = '42501';
    END IF;
    SELECT conversation.confirmation_payload -> 'property' INTO v_accepted
    FROM public.whatsapp_conversations AS conversation
    WHERE conversation.organization_id = p_organization_id
      AND conversation.confirmation_status = 'claimed'
      AND coalesce(nullif(conversation.confirmation_result #>> '{commandKeys,property}', ''),
        coalesce(nullif(conversation.confirmation_result ->> 'attemptKey', ''),
          'whatsapp:' || conversation.id::text || ':' || conversation.confirmation_key) || ':property') = p_idempotency_key
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'WhatsApp property confirmation is stale' USING ERRCODE = '40001';
    END IF;
    v_submitted := jsonb_build_object(%s);
    IF EXISTS (
      SELECT 1 FROM jsonb_each(v_submitted) AS submitted(key, value)
      WHERE submitted.value IS DISTINCT FROM coalesce(v_accepted -> submitted.key, 'null'::jsonb)
    ) THEN
      RAISE EXCEPTION 'WhatsApp property confirmation payload is stale' USING ERRCODE = '40001';
    END IF;
  END IF;
  RETURN public.create_property_v1_before_whatsapp_correction(%s);
END;
$function$;
$body$, v_property_arguments, v_arguments);
    EXECUTE format('REVOKE ALL ON FUNCTION public.create_property_v1(%s) FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker', v_types);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.create_property_v1(%s) TO authenticated', v_types);
  END LOOP;
END;
$migration$;
