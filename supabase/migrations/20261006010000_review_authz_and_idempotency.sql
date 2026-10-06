-- Close staff RPC authorization gaps and bind retries to their original command.
-- Historical migrations are preserved; obsolete implementations are private
-- implementation details behind the public guarded RPCs.

ALTER FUNCTION public.confirm_commercial_booking(uuid, uuid, text, uuid)
  RENAME TO confirm_commercial_booking_without_review_guards;
ALTER FUNCTION public.record_commercial_booking_stay_event(uuid, uuid, text, text, text, uuid)
  RENAME TO record_commercial_booking_stay_event_without_review_guards;
ALTER FUNCTION public.list_clients_v1(uuid)
  RENAME TO list_clients_v1_without_workspace_aal2;

REVOKE ALL ON FUNCTION public.confirm_commercial_booking_without_review_guards(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_commercial_booking_stay_event_without_review_guards(uuid, uuid, text, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_clients_v1_without_workspace_aal2(uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.review_booking_request_bindings (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  command_name text NOT NULL CHECK (command_name IN ('booking.confirm.v1')),
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  resource_id uuid NOT NULL,
  request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  result boolean NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (organization_id, command_name, idempotency_key),
  FOREIGN KEY (organization_id, resource_id)
    REFERENCES public.bookings(organization_id, id) ON DELETE RESTRICT
);
ALTER TABLE public.review_booking_request_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.review_booking_request_bindings FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.review_booking_request_bindings FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.confirm_commercial_booking(
  p_organization_id uuid, p_booking_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_role text;
  v_existing public.review_booking_request_bindings%ROWTYPE;
  v_legacy_booking_id uuid;
  v_request_hash text;
  v_result boolean;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_booking_id IS NULL OR p_idempotency_key IS NULL
    OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'booking confirmation input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.role INTO v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'commercial booking confirmation is not permitted' USING ERRCODE = '42501';
  END IF;

  v_request_hash := encode(extensions.digest(
    jsonb_build_object('organization_id', p_organization_id, 'booking_id', p_booking_id, 'command', 'booking.confirm.v1')::text,
    'sha256'
  ), 'hex');
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_organization_id::text || '|booking.confirm.v1|' || btrim(p_idempotency_key), 0
  ));

  SELECT binding.* INTO v_existing
  FROM public.review_booking_request_bindings AS binding
  WHERE binding.organization_id = p_organization_id
    AND binding.command_name = 'booking.confirm.v1'
    AND binding.idempotency_key = btrim(p_idempotency_key)
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.resource_id <> p_booking_id OR v_existing.request_hash <> v_request_hash THEN
      RAISE EXCEPTION 'booking confirmation key belongs to a different request' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.result;
  END IF;

  SELECT command.booking_id INTO v_legacy_booking_id
  FROM public.booking_v1_command_idempotency AS command
  WHERE command.organization_id = p_organization_id
    AND command.command_name = 'booking.confirm.v1'
    AND command.idempotency_key = btrim(p_idempotency_key)
  FOR UPDATE;
  IF FOUND THEN
    IF v_legacy_booking_id <> p_booking_id THEN
      RAISE EXCEPTION 'booking confirmation key belongs to a different booking' USING ERRCODE = '23505';
    END IF;
    v_result := public.confirm_commercial_booking_without_review_guards(
      p_organization_id, p_booking_id, p_idempotency_key, p_request_id
    );
  ELSE
    v_result := public.confirm_commercial_booking_without_review_guards(
      p_organization_id, p_booking_id, p_idempotency_key, p_request_id
    );
  END IF;

  INSERT INTO public.review_booking_request_bindings (
    organization_id, command_name, idempotency_key, resource_id, request_hash, result
  ) VALUES (
    p_organization_id, 'booking.confirm.v1', btrim(p_idempotency_key), p_booking_id, v_request_hash, v_result
  );
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_commercial_booking_stay_event(
  p_organization_id uuid, p_booking_id uuid, p_event_type text, p_notes text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_role text;
  v_existing public.booking_stay_events%ROWTYPE;
  v_result uuid;
  v_notes text := NULLIF(btrim(p_notes), '');
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_booking_id IS NULL OR p_event_type IS NULL OR p_event_type NOT IN ('check_in', 'check_out')
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160
    OR (p_notes IS NOT NULL AND char_length(btrim(p_notes)) NOT BETWEEN 1 AND 2000) THEN
    RAISE EXCEPTION 'stay event input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.role INTO v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'operations') THEN
    RAISE EXCEPTION 'stay event is not permitted' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_organization_id::text || '|booking.stay|' || btrim(p_idempotency_key), 0
  ));
  SELECT event.* INTO v_existing
  FROM public.booking_stay_events AS event
  WHERE event.organization_id = p_organization_id
    AND event.idempotency_key = btrim(p_idempotency_key)
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.booking_id <> p_booking_id OR v_existing.event_type <> p_event_type
      OR v_existing.notes IS DISTINCT FROM v_notes THEN
      RAISE EXCEPTION 'stay event key belongs to a different request' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;
  v_result := public.record_commercial_booking_stay_event_without_review_guards(
    p_organization_id, p_booking_id, p_event_type, p_notes, p_idempotency_key, p_request_id
  );
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_clients_v1(p_organization_id uuid)
RETURNS TABLE (
  id uuid, display_name text, phone text, whatsapp text, email text,
  normalized_phone text, normalized_email text, nationality text,
  preferred_language text, notes text, source_lead_id uuid, version integer,
  created_at timestamptz, updated_at timestamptz, archived_at timestamptz,
  duplicate_warning boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_clients_v1_without_workspace_aal2(p_organization_id);
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_commercial_booking(uuid, uuid, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.record_commercial_booking_stay_event(uuid, uuid, text, text, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_clients_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_commercial_booking(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_commercial_booking_stay_event(uuid, uuid, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_clients_v1(uuid) TO authenticated;

-- Keep the old generic CRM command implementation private; the guarded public
-- wrappers below serialize keys, verify assignment, and bind request payloads.
ALTER FUNCTION public.update_lead_v1(uuid, uuid, text, text, text, text, text, text, uuid, text, date, date, integer, integer, text, text, timestamptz, integer, text, uuid)
  RENAME TO update_lead_v1_without_review_guards;
ALTER FUNCTION public.archive_lead_v1(uuid, uuid, text, integer, text, uuid)
  RENAME TO archive_lead_v1_without_review_guards;
ALTER FUNCTION public.convert_lead_to_client_v1(uuid, uuid, text, uuid)
  RENAME TO convert_lead_to_client_v1_without_review_guards;
REVOKE ALL ON FUNCTION public.update_lead_v1_without_review_guards(uuid, uuid, text, text, text, text, text, text, uuid, text, date, date, integer, integer, text, text, timestamptz, integer, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.archive_lead_v1_without_review_guards(uuid, uuid, text, integer, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.convert_lead_to_client_v1_without_review_guards(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.review_crm_request_bindings (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  command_name text NOT NULL CHECK (command_name IN ('lead.update', 'lead.archive', 'lead.convert')),
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  resource_id uuid NOT NULL,
  request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (organization_id, command_name, idempotency_key),
  FOREIGN KEY (organization_id, resource_id) REFERENCES public.leads(organization_id, id) ON DELETE RESTRICT
);
ALTER TABLE public.review_crm_request_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.review_crm_request_bindings FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.review_crm_request_bindings FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.update_lead_v1(
  p_organization_id uuid, p_lead_id uuid, p_name text, p_phone text, p_whatsapp text, p_email text,
  p_source text, p_status text, p_assigned_membership_id uuid, p_requested_area text,
  p_check_in date, p_check_out date, p_guests integer, p_bedrooms integer, p_budget_text text,
  p_notes text, p_next_follow_up_at timestamptz, p_expected_version integer,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_role text;
  v_lead public.leads%ROWTYPE;
  v_binding public.review_crm_request_bindings%ROWTYPE;
  v_hash text;
  v_result boolean;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.role INTO v_role FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'lead update is not permitted' USING ERRCODE = '42501';
  END IF;
  SELECT lead_record.* INTO v_lead FROM public.leads AS lead_record
  WHERE lead_record.organization_id = p_organization_id AND lead_record.id = p_lead_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'lead was not found' USING ERRCODE = '23503'; END IF;
  IF NOT public.crm_sales_lead_write_allowed_v1(p_organization_id, p_lead_id) THEN
    RAISE EXCEPTION 'lead update is outside the actor assignment scope' USING ERRCODE = '42501';
  END IF;
  IF v_lead.assigned_membership_id IS DISTINCT FROM p_assigned_membership_id
    AND v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'lead reassignment is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'lead update idempotency key is invalid' USING ERRCODE = '22023';
  END IF;
  v_hash := encode(extensions.digest(jsonb_build_object(
    'organization_id', p_organization_id, 'lead_id', p_lead_id, 'name', p_name,
    'phone', p_phone, 'whatsapp', p_whatsapp, 'email', p_email, 'source', p_source,
    'status', p_status, 'assigned_membership_id', p_assigned_membership_id,
    'requested_area', p_requested_area, 'check_in', p_check_in, 'check_out', p_check_out,
    'guests', p_guests, 'bedrooms', p_bedrooms, 'budget_text', p_budget_text,
    'notes', p_notes, 'next_follow_up_at', p_next_follow_up_at,
    'expected_version', p_expected_version
  )::text, 'sha256'), 'hex');
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_organization_id::text || '|lead.update|' || btrim(p_idempotency_key), 0
  ));
  SELECT binding.* INTO v_binding FROM public.review_crm_request_bindings AS binding
  WHERE binding.organization_id = p_organization_id AND binding.command_name = 'lead.update'
    AND binding.idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_binding.resource_id <> p_lead_id OR v_binding.request_hash <> v_hash THEN
      RAISE EXCEPTION 'lead update key belongs to a different request' USING ERRCODE = '23505';
    END IF;
    RETURN (v_binding.result #>> '{}')::boolean;
  END IF;
  IF EXISTS (SELECT 1 FROM public.crm_v1_command_idempotency AS command
    WHERE command.organization_id = p_organization_id AND command.command = 'lead.update'
      AND command.idempotency_key = btrim(p_idempotency_key)) THEN
    RAISE EXCEPTION 'legacy lead update key has no request binding' USING ERRCODE = '23505';
  END IF;
  v_result := public.update_lead_v1_without_review_guards(
    p_organization_id, p_lead_id, p_name, p_phone, p_whatsapp, p_email, p_source,
    p_status, p_assigned_membership_id, p_requested_area, p_check_in, p_check_out,
    p_guests, p_bedrooms, p_budget_text, p_notes, p_next_follow_up_at,
    p_expected_version, p_idempotency_key, p_request_id
  );
  INSERT INTO public.review_crm_request_bindings VALUES (
    p_organization_id, 'lead.update', btrim(p_idempotency_key), p_lead_id, v_hash, to_jsonb(v_result), timezone('utc', now())
  );
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_lead_v1(
  p_organization_id uuid, p_lead_id uuid, p_reason text, p_expected_version integer,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE v_role text; v_lead public.leads%ROWTYPE; v_binding public.review_crm_request_bindings%ROWTYPE; v_hash text; v_result boolean;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.role INTO v_role FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN RAISE EXCEPTION 'lead archive is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT lead_record.* INTO v_lead FROM public.leads AS lead_record WHERE lead_record.organization_id = p_organization_id AND lead_record.id = p_lead_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'lead was not found' USING ERRCODE = '23503'; END IF;
  IF NOT public.crm_sales_lead_write_allowed_v1(p_organization_id, p_lead_id) THEN RAISE EXCEPTION 'lead archive is outside the actor assignment scope' USING ERRCODE = '42501'; END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'lead archive idempotency key is invalid' USING ERRCODE = '22023'; END IF;
  v_hash := encode(extensions.digest(jsonb_build_object('organization_id', p_organization_id, 'lead_id', p_lead_id, 'reason', p_reason, 'expected_version', p_expected_version)::text, 'sha256'), 'hex');
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_organization_id::text || '|lead.archive|' || btrim(p_idempotency_key), 0));
  SELECT binding.* INTO v_binding FROM public.review_crm_request_bindings AS binding WHERE binding.organization_id = p_organization_id AND binding.command_name = 'lead.archive' AND binding.idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_binding.resource_id <> p_lead_id OR v_binding.request_hash <> v_hash THEN RAISE EXCEPTION 'lead archive key belongs to a different request' USING ERRCODE = '23505'; END IF;
    RETURN (v_binding.result #>> '{}')::boolean;
  END IF;
  IF EXISTS (SELECT 1 FROM public.crm_v1_command_idempotency AS command WHERE command.organization_id = p_organization_id AND command.command = 'lead.archive' AND command.idempotency_key = btrim(p_idempotency_key)) THEN
    RAISE EXCEPTION 'legacy lead archive key has no request binding' USING ERRCODE = '23505';
  END IF;
  v_result := public.archive_lead_v1_without_review_guards(p_organization_id, p_lead_id, p_reason, p_expected_version, p_idempotency_key, p_request_id);
  INSERT INTO public.review_crm_request_bindings VALUES (p_organization_id, 'lead.archive', btrim(p_idempotency_key), p_lead_id, v_hash, to_jsonb(v_result), timezone('utc', now()));
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.convert_lead_to_client_v1(
  p_organization_id uuid, p_lead_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_role text;
  v_lead public.leads%ROWTYPE;
  v_binding public.review_crm_request_bindings%ROWTYPE;
  v_legacy public.crm_v1_command_idempotency%ROWTYPE;
  v_hash text;
  v_result uuid;
  v_valid_result uuid;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.role INTO v_role FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN RAISE EXCEPTION 'lead conversion is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT lead_record.* INTO v_lead FROM public.leads AS lead_record WHERE lead_record.organization_id = p_organization_id AND lead_record.id = p_lead_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'lead was not found' USING ERRCODE = '23503'; END IF;
  IF NOT public.crm_sales_lead_write_allowed_v1(p_organization_id, p_lead_id) THEN RAISE EXCEPTION 'lead conversion is outside the actor assignment scope' USING ERRCODE = '42501'; END IF;
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'lead conversion idempotency key is invalid' USING ERRCODE = '22023'; END IF;
  v_hash := encode(extensions.digest(jsonb_build_object('organization_id', p_organization_id, 'lead_id', p_lead_id, 'command', 'lead.convert')::text, 'sha256'), 'hex');
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_organization_id::text || '|lead.convert|' || btrim(p_idempotency_key), 0));
  SELECT binding.* INTO v_binding FROM public.review_crm_request_bindings AS binding WHERE binding.organization_id = p_organization_id AND binding.command_name = 'lead.convert' AND binding.idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_binding.resource_id <> p_lead_id OR v_binding.request_hash <> v_hash THEN RAISE EXCEPTION 'lead conversion key belongs to a different request' USING ERRCODE = '23505'; END IF;
    RETURN (v_binding.result #>> '{}')::uuid;
  END IF;
  SELECT command.* INTO v_legacy
  FROM public.crm_v1_command_idempotency AS command
  WHERE command.organization_id = p_organization_id
    AND command.command = 'lead.convert'
    AND command.idempotency_key = btrim(p_idempotency_key)
  FOR UPDATE;
  IF FOUND THEN
    IF v_legacy.resource_id <> p_lead_id OR v_legacy.result_id IS NULL THEN
      RAISE EXCEPTION 'legacy lead conversion key has no matching result binding' USING ERRCODE = '23505';
    END IF;
    SELECT client.id INTO v_valid_result
    FROM public.clients AS client
    JOIN public.leads AS converted_lead
      ON converted_lead.organization_id = client.organization_id
     AND converted_lead.id = p_lead_id
     AND converted_lead.converted_client_id = client.id
    WHERE client.organization_id = p_organization_id
      AND client.id = v_legacy.result_id
      AND client.source_lead_id = p_lead_id;
    IF v_valid_result IS NULL THEN
      RAISE EXCEPTION 'legacy lead conversion result no longer matches its source lead' USING ERRCODE = '23505';
    END IF;
    INSERT INTO public.review_crm_request_bindings (
      organization_id, command_name, idempotency_key, resource_id, request_hash, result
    ) VALUES (
      p_organization_id, 'lead.convert', btrim(p_idempotency_key), p_lead_id, v_hash, to_jsonb(v_valid_result)
    );
    RETURN v_valid_result;
  END IF;
  v_result := public.convert_lead_to_client_v1_without_review_guards(p_organization_id, p_lead_id, p_idempotency_key, p_request_id);
  INSERT INTO public.review_crm_request_bindings VALUES (p_organization_id, 'lead.convert', btrim(p_idempotency_key), p_lead_id, v_hash, to_jsonb(v_result), timezone('utc', now()));
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.update_lead_v1(uuid, uuid, text, text, text, text, text, text, uuid, text, date, date, integer, integer, text, text, timestamptz, integer, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.archive_lead_v1(uuid, uuid, text, integer, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.convert_lead_to_client_v1(uuid, uuid, text, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.update_lead_v1(uuid, uuid, text, text, text, text, text, text, uuid, text, date, date, integer, integer, text, text, timestamptz, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.archive_lead_v1(uuid, uuid, text, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.convert_lead_to_client_v1(uuid, uuid, text, uuid) TO authenticated;
