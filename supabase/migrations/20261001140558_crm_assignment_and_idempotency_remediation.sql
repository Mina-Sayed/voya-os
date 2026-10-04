-- Keep CRM lead writes inside the same assignment boundary as lead reads.
-- Idempotent update/activity replays are bound to their original payload.

ALTER TABLE public.crm_v1_command_idempotency
  ADD COLUMN payload_hash text,
  ADD CONSTRAINT crm_v1_command_idempotency_payload_hash_valid
    CHECK (payload_hash IS NULL OR payload_hash ~ '^[0-9a-f]{64}$');

CREATE OR REPLACE FUNCTION public.crm_update_lead_payload_hash_v1(
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_whatsapp text,
  p_email text,
  p_source text,
  p_status text,
  p_assigned_membership_id uuid,
  p_requested_area text,
  p_check_in date,
  p_check_out date,
  p_guests integer,
  p_bedrooms integer,
  p_budget_text text,
  p_notes text,
  p_next_follow_up_at timestamptz,
  p_expected_version integer
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public, extensions
AS $$
  SELECT pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'lead_id', p_lead_id,
          'name', pg_catalog.btrim(p_name),
          'phone', NULLIF(pg_catalog.btrim(p_phone), ''),
          'whatsapp', NULLIF(pg_catalog.btrim(p_whatsapp), ''),
          'email', NULLIF(pg_catalog.lower(pg_catalog.btrim(p_email)), ''),
          'normalized_phone', public.crm_normalize_phone(p_phone),
          'normalized_email', public.crm_normalize_email(p_email),
          'source', p_source,
          'status', p_status,
          'assigned_membership_id', p_assigned_membership_id,
          'requested_area', NULLIF(pg_catalog.btrim(p_requested_area), ''),
          'check_in', p_check_in,
          'check_out', p_check_out,
          'guests', p_guests,
          'bedrooms', p_bedrooms,
          'budget_text', NULLIF(pg_catalog.btrim(p_budget_text), ''),
          'notes', NULLIF(pg_catalog.btrim(p_notes), ''),
          'next_follow_up_at', p_next_follow_up_at,
          'expected_version', p_expected_version
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

CREATE OR REPLACE FUNCTION public.crm_create_lead_activity_payload_hash_v1(
  p_lead_id uuid,
  p_activity_type text,
  p_content text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, extensions
AS $$
  SELECT pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'lead_id', p_lead_id,
          'activity_type', p_activity_type,
          'content', pg_catalog.btrim(p_content)
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

REVOKE ALL ON FUNCTION public.crm_update_lead_payload_hash_v1(
  uuid, text, text, text, text, text, text, uuid, text, date, date,
  integer, integer, text, text, timestamptz, integer
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.crm_create_lead_activity_payload_hash_v1(uuid, text, text)
  FROM PUBLIC, anon, authenticated;

-- Existing activities retain enough immutable evidence to recover their
-- canonical payload. Updates are backfilled only when no later lead mutation
-- has overwritten the resulting state; ambiguous older keys fail closed.
UPDATE public.crm_v1_command_idempotency AS command_record
SET payload_hash = public.crm_create_lead_activity_payload_hash_v1(
  activity.lead_id, activity.activity_type, activity.content
)
FROM public.crm_activities AS activity
WHERE command_record.organization_id = activity.organization_id
  AND command_record.command = 'lead.activity.create'
  AND command_record.resource_id = activity.lead_id
  AND command_record.result_id = activity.id
  AND command_record.payload_hash IS NULL;

UPDATE public.crm_v1_command_idempotency AS command_record
SET payload_hash = public.crm_update_lead_payload_hash_v1(
  lead_record.id,
  COALESCE(lead_record.name, lead_record.title),
  lead_record.phone,
  lead_record.whatsapp,
  lead_record.email,
  lead_record.source,
  lead_record.status,
  lead_record.assigned_membership_id,
  lead_record.requested_area,
  lead_record.requested_check_in,
  lead_record.requested_check_out,
  lead_record.guests,
  lead_record.bedrooms,
  lead_record.budget_text,
  lead_record.notes,
  lead_record.next_follow_up_at,
  command_record.result_version - 1
)
FROM public.leads AS lead_record
WHERE command_record.organization_id = lead_record.organization_id
  AND command_record.command = 'lead.update'
  AND command_record.resource_id = lead_record.id
  AND command_record.result_version = lead_record.version
  AND command_record.payload_hash IS NULL;

ALTER FUNCTION public.update_lead_v1(
  uuid, uuid, text, text, text, text, text, text, uuid, text, date, date,
  integer, integer, text, text, timestamptz, integer, text, uuid
) RENAME TO update_lead_v1_without_assignment_payload_binding;
ALTER FUNCTION public.archive_lead_v1(uuid, uuid, text, integer, text, uuid)
  RENAME TO archive_lead_v1_without_assignment_scope;
ALTER FUNCTION public.convert_lead_to_client_v1(uuid, uuid, text, uuid)
  RENAME TO convert_lead_to_client_v1_without_assignment_scope;
ALTER FUNCTION public.create_lead_activity_v1(uuid, uuid, text, text, text, uuid)
  RENAME TO create_lead_activity_v1_without_assignment_payload_binding;

REVOKE ALL ON FUNCTION public.update_lead_v1_without_assignment_payload_binding(
  uuid, uuid, text, text, text, text, text, text, uuid, text, date, date,
  integer, integer, text, text, timestamptz, integer, text, uuid
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.archive_lead_v1_without_assignment_scope(uuid, uuid, text, integer, text, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.convert_lead_to_client_v1_without_assignment_scope(uuid, uuid, text, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_lead_activity_v1_without_assignment_payload_binding(uuid, uuid, text, text, text, uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.update_lead_v1(
  p_organization_id uuid,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_whatsapp text,
  p_email text,
  p_source text,
  p_status text,
  p_assigned_membership_id uuid,
  p_requested_area text,
  p_check_in date,
  p_check_out date,
  p_guests integer,
  p_bedrooms integer,
  p_budget_text text,
  p_notes text,
  p_next_follow_up_at timestamptz,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid;
  v_lead public.leads%ROWTYPE;
  v_existing public.crm_v1_command_idempotency%ROWTYPE;
  v_payload_hash text;
  v_result boolean;
  v_rows integer;
BEGIN
  IF p_lead_id IS NULL OR p_name IS NULL OR pg_catalog.char_length(pg_catalog.btrim(p_name)) NOT BETWEEN 1 AND 160
    OR (public.crm_normalize_phone(p_phone) IS NULL AND public.crm_normalize_phone(p_whatsapp) IS NULL AND public.crm_normalize_email(p_email) IS NULL)
    OR p_source IS NULL OR p_source !~ '^[a-z][a-z0-9_-]{0,63}$'
    OR p_status NOT IN ('new', 'contacted', 'qualified', 'offered', 'won', 'lost')
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR pg_catalog.char_length(pg_catalog.btrim(p_idempotency_key)) = 0
    OR ((p_check_in IS NULL) <> (p_check_out IS NULL))
    OR (p_check_in IS NOT NULL AND p_check_in >= p_check_out)
    OR (p_guests IS NOT NULL AND p_guests NOT BETWEEN 1 AND 50)
    OR (p_bedrooms IS NOT NULL AND p_bedrooms NOT BETWEEN 0 AND 100) THEN
    RAISE EXCEPTION 'lead update input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'lead update is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT lead_record.* INTO v_lead
  FROM public.leads AS lead_record
  WHERE lead_record.organization_id = p_organization_id
    AND lead_record.id = p_lead_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lead was not found' USING ERRCODE = '23503';
  END IF;

  IF NOT public.crm_sales_lead_write_allowed_v1(p_organization_id, p_lead_id) THEN
    RAISE EXCEPTION 'lead update is not permitted for this assignment' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text || ':lead.update:' || p_idempotency_key, 0)
  );
  v_payload_hash := public.crm_update_lead_payload_hash_v1(
    p_lead_id, p_name, p_phone, p_whatsapp, p_email, p_source, p_status,
    p_assigned_membership_id, p_requested_area, p_check_in, p_check_out,
    p_guests, p_bedrooms, p_budget_text, p_notes, p_next_follow_up_at,
    p_expected_version
  );

  SELECT command_record.* INTO v_existing
  FROM public.crm_v1_command_idempotency AS command_record
  WHERE command_record.organization_id = p_organization_id
    AND command_record.command = 'lead.update'
    AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.resource_id = p_lead_id
      AND v_existing.payload_hash IS NOT NULL
      AND v_existing.payload_hash = v_payload_hash THEN
      RETURN true;
    END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different lead update payload' USING ERRCODE = '23505';
  END IF;

  v_result := public.update_lead_v1_without_assignment_payload_binding(
    p_organization_id, p_lead_id, p_name, p_phone, p_whatsapp, p_email,
    p_source, p_status, p_assigned_membership_id, p_requested_area,
    p_check_in, p_check_out, p_guests, p_bedrooms, p_budget_text, p_notes,
    p_next_follow_up_at, p_expected_version, p_idempotency_key, p_request_id
  );
  UPDATE public.crm_v1_command_idempotency AS command_record
  SET payload_hash = v_payload_hash
  WHERE command_record.organization_id = p_organization_id
    AND command_record.command = 'lead.update'
    AND command_record.resource_id = p_lead_id
    AND command_record.idempotency_key = p_idempotency_key;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'lead update idempotency result was not recorded' USING ERRCODE = '23505';
  END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_lead_v1(
  p_organization_id uuid,
  p_lead_id uuid,
  p_reason text,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_lead public.leads%ROWTYPE;
BEGIN
  IF p_lead_id IS NULL OR p_reason IS NULL OR pg_catalog.char_length(pg_catalog.btrim(p_reason)) = 0
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR pg_catalog.char_length(pg_catalog.btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'lead archive input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'lead archive is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT lead_record.* INTO v_lead
  FROM public.leads AS lead_record
  WHERE lead_record.organization_id = p_organization_id
    AND lead_record.id = p_lead_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lead was not found or version is stale' USING ERRCODE = '40001';
  END IF;
  IF NOT public.crm_sales_lead_write_allowed_v1(p_organization_id, p_lead_id) THEN
    RAISE EXCEPTION 'lead archive is not permitted for this assignment' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text || ':lead.archive:' || p_idempotency_key, 0)
  );
  RETURN public.archive_lead_v1_without_assignment_scope(
    p_organization_id, p_lead_id, p_reason, p_expected_version,
    p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.convert_lead_to_client_v1(
  p_organization_id uuid,
  p_lead_id uuid,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_lead public.leads%ROWTYPE;
BEGIN
  IF p_lead_id IS NULL OR p_idempotency_key IS NULL
    OR pg_catalog.char_length(pg_catalog.btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'lead conversion input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'lead conversion is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT lead_record.* INTO v_lead
  FROM public.leads AS lead_record
  WHERE lead_record.organization_id = p_organization_id
    AND lead_record.id = p_lead_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lead was not found' USING ERRCODE = '23503';
  END IF;
  IF NOT public.crm_sales_lead_write_allowed_v1(p_organization_id, p_lead_id) THEN
    RAISE EXCEPTION 'lead conversion is not permitted for this assignment' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text || ':lead.convert:' || p_idempotency_key, 0)
  );
  RETURN public.convert_lead_to_client_v1_without_assignment_scope(
    p_organization_id, p_lead_id, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.create_lead_activity_v1(
  p_organization_id uuid,
  p_lead_id uuid,
  p_activity_type text,
  p_content text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid;
  v_lead public.leads%ROWTYPE;
  v_existing public.crm_v1_command_idempotency%ROWTYPE;
  v_payload_hash text;
  v_id uuid;
  v_rows integer;
BEGIN
  IF p_lead_id IS NULL
    OR p_activity_type NOT IN ('call', 'whatsapp', 'email', 'note', 'status_change', 'property_offered', 'booking_created')
    OR p_content IS NULL OR pg_catalog.char_length(pg_catalog.btrim(p_content)) NOT BETWEEN 1 AND 4000
    OR p_idempotency_key IS NULL OR pg_catalog.char_length(pg_catalog.btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'lead activity input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'lead activity is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT lead_record.* INTO v_lead
  FROM public.leads AS lead_record
  WHERE lead_record.organization_id = p_organization_id
    AND lead_record.id = p_lead_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lead was not found' USING ERRCODE = '23503';
  END IF;
  IF NOT public.crm_sales_lead_write_allowed_v1(p_organization_id, p_lead_id) THEN
    RAISE EXCEPTION 'lead activity is not permitted for this assignment' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_organization_id::text || ':lead.activity.create:' || p_idempotency_key, 0)
  );
  v_payload_hash := public.crm_create_lead_activity_payload_hash_v1(
    p_lead_id, p_activity_type, p_content
  );

  SELECT command_record.* INTO v_existing
  FROM public.crm_v1_command_idempotency AS command_record
  WHERE command_record.organization_id = p_organization_id
    AND command_record.command = 'lead.activity.create'
    AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.resource_id = p_lead_id
      AND v_existing.result_id IS NOT NULL
      AND v_existing.payload_hash IS NOT NULL
      AND v_existing.payload_hash = v_payload_hash THEN
      RETURN v_existing.result_id;
    END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different lead activity payload' USING ERRCODE = '23505';
  END IF;

  v_id := public.create_lead_activity_v1_without_assignment_payload_binding(
    p_organization_id, p_lead_id, p_activity_type, p_content,
    p_idempotency_key, p_request_id
  );
  UPDATE public.crm_v1_command_idempotency AS command_record
  SET payload_hash = v_payload_hash
  WHERE command_record.organization_id = p_organization_id
    AND command_record.command = 'lead.activity.create'
    AND command_record.resource_id = p_lead_id
    AND command_record.idempotency_key = p_idempotency_key;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 OR v_id IS NULL THEN
    RAISE EXCEPTION 'lead activity idempotency result was not recorded' USING ERRCODE = '23505';
  END IF;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.update_lead_v1(
  uuid, uuid, text, text, text, text, text, text, uuid, text, date, date,
  integer, integer, text, text, timestamptz, integer, text, uuid
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.archive_lead_v1(uuid, uuid, text, integer, text, uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.convert_lead_to_client_v1(uuid, uuid, text, uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_lead_activity_v1(uuid, uuid, text, text, text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_lead_v1(
  uuid, uuid, text, text, text, text, text, text, uuid, text, date, date,
  integer, integer, text, text, timestamptz, integer, text, uuid
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.archive_lead_v1(uuid, uuid, text, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.convert_lead_to_client_v1(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_lead_activity_v1(uuid, uuid, text, text, text, uuid) TO authenticated;
