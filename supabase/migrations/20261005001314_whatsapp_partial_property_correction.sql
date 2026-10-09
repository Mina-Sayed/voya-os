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
      -- Match the command/parser's text normalization and boolean/array defaults.
      WHERE CASE
        WHEN submitted.key IN ('code', 'name', 'timezone', 'address', 'city', 'unitLabel', 'operationalNotes', 'floor', 'district', 'marketingDescription')
          THEN coalesce(to_jsonb(nullif(btrim(submitted.value #>> '{}'), '')), 'null'::jsonb)
        WHEN submitted.key IN ('rentDaily', 'rentWeekly', 'rentMonthly')
          THEN to_jsonb(coalesce((submitted.value #>> '{}')::boolean, false))
        WHEN submitted.key = 'amenities' THEN coalesce(nullif(submitted.value, 'null'::jsonb), '[]'::jsonb)
        ELSE submitted.value END
      IS DISTINCT FROM CASE
        WHEN submitted.key IN ('code', 'name', 'timezone', 'address', 'city', 'unitLabel', 'operationalNotes', 'floor', 'district', 'marketingDescription')
          THEN coalesce(to_jsonb(nullif(btrim(v_accepted ->> submitted.key), '')), 'null'::jsonb)
        WHEN submitted.key IN ('rentDaily', 'rentWeekly', 'rentMonthly')
          THEN to_jsonb(coalesce((v_accepted ->> submitted.key)::boolean, false))
        WHEN submitted.key = 'amenities' THEN coalesce(nullif(v_accepted -> submitted.key, 'null'::jsonb), '[]'::jsonb)
        ELSE coalesce(v_accepted -> submitted.key, 'null'::jsonb) END
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
