-- Voya OS V1: complete the rentable-inventory contract without changing the
-- existing booking/occupancy source of truth. All browser access remains RPC-only.

ALTER TABLE public.properties
  DROP CONSTRAINT IF EXISTS properties_status_check;
ALTER TABLE public.properties
  ADD CONSTRAINT properties_status_check
  CHECK (status IN ('active', 'inactive', 'archived'));
ALTER TABLE public.properties
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS unit_label text,
  ADD COLUMN IF NOT EXISTS bedrooms integer,
  ADD COLUMN IF NOT EXISTS max_guests integer,
  ADD COLUMN IF NOT EXISTS operational_notes text,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;
ALTER TABLE public.properties
  ADD CONSTRAINT properties_bedrooms_valid
  CHECK (bedrooms IS NULL OR (bedrooms >= 0 AND bedrooms <= 100));
ALTER TABLE public.properties
  ADD CONSTRAINT properties_max_guests_valid
  CHECK (max_guests IS NULL OR (max_guests >= 1 AND max_guests <= 1000));
ALTER TABLE public.properties
  ADD CONSTRAINT properties_archived_at_consistent
  CHECK ((status = 'archived') = (archived_at IS NOT NULL));

ALTER TABLE public.property_owners
  DROP CONSTRAINT IF EXISTS property_owners_status_check;
ALTER TABLE public.property_owners
  ADD CONSTRAINT property_owners_status_check
  CHECK (status IN ('active', 'inactive', 'archived'));
ALTER TABLE public.property_owners
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS whatsapp text,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS preferred_contact_method text,
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1;
ALTER TABLE public.property_owners
  ADD CONSTRAINT property_owners_version_valid
  CHECK (version > 0);
ALTER TABLE public.property_owners
  ADD CONSTRAINT property_owners_archived_at_consistent
  CHECK ((status = 'archived') = (archived_at IS NOT NULL));
ALTER TABLE public.property_owners
  ADD CONSTRAINT property_owners_contact_method_valid
  CHECK (preferred_contact_method IS NULL OR preferred_contact_method IN ('phone', 'whatsapp', 'email', 'none'));

ALTER TABLE public.property_ownership_periods
  ADD COLUMN IF NOT EXISTS is_primary_contact boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS idempotency_key text;
ALTER TABLE public.property_ownership_periods
  ADD CONSTRAINT property_ownership_period_idempotency_unique
  UNIQUE (organization_id, idempotency_key);

CREATE TABLE public.property_v1_command_idempotency (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  command text NOT NULL CHECK (command IN ('property.update', 'property.archive', 'property.restore', 'property_owner.update', 'property_owner.archive', 'property_owner.restore')),
  resource_id uuid NOT NULL,
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) > 0),
  result_version integer,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, command, idempotency_key)
);

CREATE TABLE public.property_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  property_id uuid NOT NULL,
  storage_bucket text NOT NULL DEFAULT 'property-images',
  storage_path text NOT NULL,
  mime_type text NOT NULL,
  byte_size bigint NOT NULL,
  width_px integer,
  height_px integer,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) > 0),
  created_by_membership_id uuid NOT NULL,
  archived_by_membership_id uuid,
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, idempotency_key),
  CONSTRAINT property_image_property_tenant_fk
    FOREIGN KEY (organization_id, property_id)
    REFERENCES public.properties (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT property_image_created_by_tenant_fk
    FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT property_image_archived_by_tenant_fk
    FOREIGN KEY (organization_id, archived_by_membership_id)
    REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT property_image_bucket_valid
    CHECK (storage_bucket = 'property-images'),
  CONSTRAINT property_image_path_shape_valid
    CHECK (storage_path = lower(storage_path)
      AND storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'),
  CONSTRAINT property_image_mime_valid
    CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/webp')),
  CONSTRAINT property_image_size_valid
    CHECK (byte_size > 0 AND byte_size <= 10485760),
  CONSTRAINT property_image_dimensions_valid
    CHECK ((width_px IS NULL AND height_px IS NULL)
      OR (width_px IS NOT NULL AND height_px IS NOT NULL AND width_px > 0 AND height_px > 0 AND width_px <= 20000 AND height_px <= 20000)),
  CONSTRAINT property_image_archived_consistent
    CHECK ((status = 'archived') = (archived_at IS NOT NULL))
);

-- The local SQL harness intentionally omits Supabase Storage. When the
-- platform schema exists, declare the bucket as private and enforce its
-- provider-side size/MIME ceiling; the app still uses the service-role path
-- plus the tenant-scoped metadata RPC below.
DO $$
BEGIN
  IF to_regclass('storage.buckets') IS NOT NULL THEN
    EXECUTE $storage$
      INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
      VALUES ('property-images', 'property-images', false, 10485760, ARRAY['image/jpeg', 'image/png', 'image/webp']::text[])
      ON CONFLICT (id) DO UPDATE
        SET name = EXCLUDED.name,
            public = false,
            file_size_limit = EXCLUDED.file_size_limit,
            allowed_mime_types = EXCLUDED.allowed_mime_types
    $storage$;
  END IF;
END;
$$;

CREATE INDEX property_images_property_active_idx
  ON public.property_images (organization_id, property_id, created_at DESC)
  WHERE status = 'active';
CREATE INDEX property_ownership_periods_current_idx
  ON public.property_ownership_periods (organization_id, property_id, start_date, end_date);
CREATE TRIGGER property_images_set_updated_at
  BEFORE UPDATE ON public.property_images
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.property_v1_command_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.property_v1_command_idempotency FORCE ROW LEVEL SECURITY;
ALTER TABLE public.property_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.property_images FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.property_v1_command_idempotency, public.property_images FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.create_property_v1(
  p_organization_id uuid,
  p_code text,
  p_name text,
  p_timezone text,
  p_address text,
  p_city text,
  p_unit_label text,
  p_bedrooms integer,
  p_max_guests integer,
  p_operational_notes text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing public.properties%ROWTYPE;
  v_property_id uuid;
BEGIN
  IF p_organization_id IS NULL
    OR p_code IS NULL OR char_length(btrim(p_code)) = 0
    OR p_name IS NULL OR char_length(btrim(p_name)) = 0
    OR p_timezone IS NULL OR char_length(btrim(p_timezone)) = 0
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'property input is incomplete' USING ERRCODE = '22023';
  END IF;
  IF p_bedrooms IS NOT NULL AND (p_bedrooms < 0 OR p_bedrooms > 100)
    OR p_max_guests IS NOT NULL AND (p_max_guests < 1 OR p_max_guests > 1000) THEN
    RAISE EXCEPTION 'property capacity is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO v_actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'property creation is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT property_record.* INTO v_existing
  FROM public.properties AS property_record
  WHERE property_record.organization_id = p_organization_id
    AND property_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.code = p_code
      AND v_existing.name = p_name
      AND v_existing.timezone = p_timezone
      AND v_existing.address IS NOT DISTINCT FROM p_address
      AND v_existing.city IS NOT DISTINCT FROM p_city
      AND v_existing.unit_label IS NOT DISTINCT FROM p_unit_label
      AND v_existing.bedrooms IS NOT DISTINCT FROM p_bedrooms
      AND v_existing.max_guests IS NOT DISTINCT FROM p_max_guests
      AND v_existing.operational_notes IS NOT DISTINCT FROM p_operational_notes
      AND v_existing.status = 'active' THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.properties (
    organization_id, code, name, timezone, address, city, unit_label,
    bedrooms, max_guests, operational_notes, status, idempotency_key
  ) VALUES (
    p_organization_id, btrim(p_code), btrim(p_name), btrim(p_timezone),
    NULLIF(btrim(p_address), ''), NULLIF(btrim(p_city), ''), NULLIF(btrim(p_unit_label), ''),
    p_bedrooms, p_max_guests, NULLIF(btrim(p_operational_notes), ''), 'active', p_idempotency_key
  ) RETURNING id INTO v_property_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor_membership_id, 'property.created', 'property',
    v_property_id, 'success', p_request_id,
    jsonb_build_object('code', btrim(p_code), 'name', btrim(p_name), 'status', 'active', 'city', NULLIF(btrim(p_city), ''))
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'property.created', 1, 'property-v1:' || v_property_id::text,
    jsonb_build_object('property_id', v_property_id)
  );
  RETURN v_property_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_properties_v1(p_organization_id uuid)
RETURNS TABLE (
  id uuid,
  code text,
  name text,
  timezone text,
  address text,
  city text,
  unit_label text,
  bedrooms integer,
  max_guests integer,
  operational_notes text,
  status text,
  version integer,
  created_at timestamptz,
  updated_at timestamptz,
  archived_at timestamptz,
  current_property_owner_id uuid,
  current_property_owner_name text,
  image_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id
      AND membership.user_id = auth.uid()
      AND membership.status = 'active'
  ) THEN
    RAISE EXCEPTION 'property read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT property_record.id,
         property_record.code,
         property_record.name,
         property_record.timezone,
         property_record.address,
         property_record.city,
         property_record.unit_label,
         property_record.bedrooms,
         property_record.max_guests,
         property_record.operational_notes,
         property_record.status,
         property_record.version,
         property_record.created_at,
         property_record.updated_at,
         property_record.archived_at,
         current_owner.property_owner_id,
         current_owner.display_name,
         (SELECT count(*)::integer FROM public.property_images AS image
          WHERE image.organization_id = p_organization_id
            AND image.property_id = property_record.id
            AND image.status = 'active')
  FROM public.properties AS property_record
  LEFT JOIN LATERAL (
    SELECT period.property_owner_id, owner_record.display_name
    FROM public.property_ownership_periods AS period
    JOIN public.property_owners AS owner_record
      ON owner_record.organization_id = period.organization_id
     AND owner_record.id = period.property_owner_id
    WHERE period.organization_id = p_organization_id
      AND period.property_id = property_record.id
      AND period.start_date <= CURRENT_DATE
      AND period.end_date > CURRENT_DATE
      AND owner_record.status = 'active'
    ORDER BY period.is_primary_contact DESC, period.start_date DESC, period.id DESC
    LIMIT 1
  ) AS current_owner ON true
  WHERE property_record.organization_id = p_organization_id
  ORDER BY property_record.created_at DESC, property_record.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_property_v1(
  p_organization_id uuid,
  p_property_id uuid,
  p_code text,
  p_name text,
  p_timezone text,
  p_address text,
  p_city text,
  p_unit_label text,
  p_bedrooms integer,
  p_max_guests integer,
  p_operational_notes text,
  p_status text,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing_command public.property_v1_command_idempotency%ROWTYPE;
  v_before public.properties%ROWTYPE;
  v_new_version integer;
BEGIN
  IF p_organization_id IS NULL OR p_property_id IS NULL
    OR p_code IS NULL OR char_length(btrim(p_code)) = 0
    OR p_name IS NULL OR char_length(btrim(p_name)) = 0
    OR p_timezone IS NULL OR char_length(btrim(p_timezone)) = 0
    OR p_status NOT IN ('active', 'inactive')
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'property update input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_bedrooms IS NOT NULL AND (p_bedrooms < 0 OR p_bedrooms > 100)
    OR p_max_guests IS NOT NULL AND (p_max_guests < 1 OR p_max_guests > 1000) THEN
    RAISE EXCEPTION 'property capacity is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO v_actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'property update is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT command_record.* INTO v_existing_command
  FROM public.property_v1_command_idempotency AS command_record
  WHERE command_record.organization_id = p_organization_id
    AND command_record.command = 'property.update'
    AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_command.resource_id = p_property_id THEN RETURN true; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property update' USING ERRCODE = '23505';
  END IF;

  SELECT property_record.* INTO v_before
  FROM public.properties AS property_record
  WHERE property_record.organization_id = p_organization_id
    AND property_record.id = p_property_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'property was not found' USING ERRCODE = '23503';
  END IF;
  IF v_before.status = 'archived' THEN
    RAISE EXCEPTION 'archived property must be restored before editing' USING ERRCODE = '22023';
  END IF;

  UPDATE public.properties
  SET code = btrim(p_code),
      name = btrim(p_name),
      timezone = btrim(p_timezone),
      address = NULLIF(btrim(p_address), ''),
      city = NULLIF(btrim(p_city), ''),
      unit_label = NULLIF(btrim(p_unit_label), ''),
      bedrooms = p_bedrooms,
      max_guests = p_max_guests,
      operational_notes = NULLIF(btrim(p_operational_notes), ''),
      status = p_status,
      archived_at = NULL,
      version = version + 1
  WHERE organization_id = p_organization_id
    AND id = p_property_id
    AND version = p_expected_version
  RETURNING version INTO v_new_version;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'property version is stale' USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.property_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_version)
  VALUES (p_organization_id, 'property.update', p_property_id, p_idempotency_key, v_new_version);
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor_membership_id, 'property.updated', 'property',
    p_property_id, 'success', p_request_id,
    jsonb_build_object('version', v_before.version, 'status', v_before.status),
    jsonb_build_object('version', v_new_version, 'status', p_status, 'code', btrim(p_code))
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'property.updated', 1,
    'property-v1-update:' || p_property_id::text || ':' || p_idempotency_key,
    jsonb_build_object('property_id', p_property_id, 'version', v_new_version)
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_property_v1(
  p_organization_id uuid,
  p_property_id uuid,
  p_reason text,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing_command public.property_v1_command_idempotency%ROWTYPE;
  v_new_version integer;
BEGIN
  IF p_property_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0
    OR p_reason IS NULL OR char_length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'property archive input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN RAISE EXCEPTION 'property archive is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT command_record.* INTO v_existing_command
  FROM public.property_v1_command_idempotency AS command_record
  WHERE command_record.organization_id = p_organization_id
    AND command_record.command = 'property.archive'
    AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_command.resource_id = p_property_id THEN RETURN true; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property archive' USING ERRCODE = '23505';
  END IF;
  UPDATE public.properties
  SET status = 'archived', archived_at = timezone('utc', now()), version = version + 1
  WHERE organization_id = p_organization_id AND id = p_property_id AND version = p_expected_version AND status <> 'archived'
  RETURNING version INTO v_new_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'property was not found or version is stale' USING ERRCODE = '40001'; END IF;
  INSERT INTO public.property_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_version)
  VALUES (p_organization_id, 'property.archive', p_property_id, p_idempotency_key, v_new_version);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta)
  VALUES (p_organization_id, 'user', v_actor_membership_id, 'property.archived', 'property', p_property_id, 'success', p_request_id, 'user_requested', jsonb_build_object('version', v_new_version, 'reason', btrim(p_reason)));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'property.archived', 1, 'property-v1-archive:' || p_property_id::text || ':' || p_idempotency_key, jsonb_build_object('property_id', p_property_id, 'version', v_new_version));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_property_v1(
  p_organization_id uuid,
  p_property_id uuid,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing_command public.property_v1_command_idempotency%ROWTYPE;
  v_new_version integer;
BEGIN
  IF p_property_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'property restore input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN RAISE EXCEPTION 'property restore is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT command_record.* INTO v_existing_command FROM public.property_v1_command_idempotency AS command_record
  WHERE command_record.organization_id = p_organization_id AND command_record.command = 'property.restore' AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_command.resource_id = p_property_id THEN RETURN true; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property restore' USING ERRCODE = '23505';
  END IF;
  UPDATE public.properties
  SET status = 'inactive', archived_at = NULL, version = version + 1
  WHERE organization_id = p_organization_id AND id = p_property_id AND version = p_expected_version AND status = 'archived'
  RETURNING version INTO v_new_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'archived property was not found or version is stale' USING ERRCODE = '40001'; END IF;
  INSERT INTO public.property_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_version)
  VALUES (p_organization_id, 'property.restore', p_property_id, p_idempotency_key, v_new_version);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor_membership_id, 'property.restored', 'property', p_property_id, 'success', p_request_id, jsonb_build_object('version', v_new_version, 'status', 'inactive'));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'property.restored', 1, 'property-v1-restore:' || p_property_id::text || ':' || p_idempotency_key, jsonb_build_object('property_id', p_property_id, 'version', v_new_version));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_property_owner_v1(
  p_organization_id uuid,
  p_display_name text,
  p_phone text,
  p_whatsapp text,
  p_email text,
  p_preferred_contact_method text,
  p_notes text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing public.property_owners%ROWTYPE;
  v_owner_id uuid;
BEGIN
  IF p_organization_id IS NULL OR p_display_name IS NULL OR char_length(btrim(p_display_name)) = 0
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'property owner input is incomplete' USING ERRCODE = '22023';
  END IF;
  IF p_preferred_contact_method IS NOT NULL AND p_preferred_contact_method NOT IN ('phone', 'whatsapp', 'email', 'none') THEN
    RAISE EXCEPTION 'preferred contact method is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN RAISE EXCEPTION 'property owner creation is not permitted' USING ERRCODE = '42501'; END IF;

  SELECT owner_record.* INTO v_existing FROM public.property_owners AS owner_record
  WHERE owner_record.organization_id = p_organization_id AND owner_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.display_name = btrim(p_display_name)
      AND v_existing.phone IS NOT DISTINCT FROM NULLIF(btrim(p_phone), '')
      AND v_existing.whatsapp IS NOT DISTINCT FROM NULLIF(btrim(p_whatsapp), '')
      AND v_existing.email IS NOT DISTINCT FROM NULLIF(lower(btrim(p_email)), '')
      AND v_existing.preferred_contact_method IS NOT DISTINCT FROM p_preferred_contact_method
      AND v_existing.notes IS NOT DISTINCT FROM NULLIF(btrim(p_notes), '')
      AND v_existing.status = 'active' THEN RETURN v_existing.id; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property owner' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.property_owners (organization_id, display_name, phone, whatsapp, email, preferred_contact_method, notes, status, idempotency_key)
  VALUES (p_organization_id, btrim(p_display_name), NULLIF(btrim(p_phone), ''), NULLIF(btrim(p_whatsapp), ''), NULLIF(lower(btrim(p_email)), ''), p_preferred_contact_method, NULLIF(btrim(p_notes), ''), 'active', p_idempotency_key)
  RETURNING id INTO v_owner_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor_membership_id, 'property_owner.created', 'property_owner', v_owner_id, 'success', p_request_id, jsonb_build_object('display_name', btrim(p_display_name), 'status', 'active'));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'property_owner.created', 1, 'property-owner-v1:' || v_owner_id::text, jsonb_build_object('property_owner_id', v_owner_id));
  RETURN v_owner_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_property_owners_v1(p_organization_id uuid)
RETURNS TABLE (
  id uuid,
  display_name text,
  phone text,
  whatsapp text,
  email text,
  preferred_contact_method text,
  notes text,
  status text,
  version integer,
  created_at timestamptz,
  archived_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
      AND membership.status = 'active'
  ) THEN RAISE EXCEPTION 'property owner read is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY SELECT owner_record.id, owner_record.display_name, owner_record.phone, owner_record.whatsapp,
    owner_record.email, owner_record.preferred_contact_method, owner_record.notes, owner_record.status,
    owner_record.version, owner_record.created_at, owner_record.archived_at
  FROM public.property_owners AS owner_record
  WHERE owner_record.organization_id = p_organization_id
  ORDER BY owner_record.created_at DESC, owner_record.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_property_owner_v1(
  p_organization_id uuid,
  p_property_owner_id uuid,
  p_display_name text,
  p_phone text,
  p_whatsapp text,
  p_email text,
  p_preferred_contact_method text,
  p_notes text,
  p_status text,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing_command public.property_v1_command_idempotency%ROWTYPE;
  v_before public.property_owners%ROWTYPE;
  v_new_version integer;
BEGIN
  IF p_property_owner_id IS NULL OR p_display_name IS NULL OR char_length(btrim(p_display_name)) = 0
    OR p_status NOT IN ('active', 'inactive') OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'property owner update input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_preferred_contact_method IS NOT NULL AND p_preferred_contact_method NOT IN ('phone', 'whatsapp', 'email', 'none') THEN
    RAISE EXCEPTION 'preferred contact method is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor_membership_id FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN RAISE EXCEPTION 'property owner update is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT command_record.* INTO v_existing_command FROM public.property_v1_command_idempotency AS command_record
  WHERE command_record.organization_id = p_organization_id AND command_record.command = 'property_owner.update' AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_command.resource_id = p_property_owner_id THEN RETURN true; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property owner update' USING ERRCODE = '23505';
  END IF;
  SELECT owner_record.* INTO v_before FROM public.property_owners AS owner_record
  WHERE owner_record.organization_id = p_organization_id AND owner_record.id = p_property_owner_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'property owner was not found' USING ERRCODE = '23503'; END IF;
  IF v_before.status = 'archived' THEN RAISE EXCEPTION 'archived property owner must be restored before editing' USING ERRCODE = '22023'; END IF;
  UPDATE public.property_owners
  SET display_name = btrim(p_display_name),
      phone = NULLIF(btrim(p_phone), ''),
      whatsapp = NULLIF(btrim(p_whatsapp), ''),
      email = NULLIF(lower(btrim(p_email)), ''),
      preferred_contact_method = p_preferred_contact_method,
      notes = NULLIF(btrim(p_notes), ''),
      status = p_status,
      archived_at = NULL,
      version = version + 1
  WHERE organization_id = p_organization_id AND id = p_property_owner_id AND version = p_expected_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'property owner version is stale' USING ERRCODE = '40001'; END IF;
  SELECT version INTO v_new_version FROM public.property_owners WHERE organization_id = p_organization_id AND id = p_property_owner_id;
  INSERT INTO public.property_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_version)
  VALUES (p_organization_id, 'property_owner.update', p_property_owner_id, p_idempotency_key, v_new_version);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, before_delta, after_delta)
  VALUES (p_organization_id, 'user', v_actor_membership_id, 'property_owner.updated', 'property_owner', p_property_owner_id, 'success', p_request_id, jsonb_build_object('version', v_before.version, 'status', v_before.status), jsonb_build_object('version', v_new_version, 'status', p_status));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'property_owner.updated', 1, 'property-owner-v1-update:' || p_property_owner_id::text || ':' || p_idempotency_key, jsonb_build_object('property_owner_id', p_property_owner_id, 'version', v_new_version));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_property_owner_v1(
  p_organization_id uuid,
  p_property_owner_id uuid,
  p_reason text,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing_command public.property_v1_command_idempotency%ROWTYPE;
  v_new_version integer;
BEGIN
  IF p_property_owner_id IS NULL OR p_reason IS NULL OR char_length(btrim(p_reason)) = 0
    OR p_expected_version IS NULL OR p_expected_version < 1 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'property owner archive input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor_membership_id FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN RAISE EXCEPTION 'property owner archive is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT command_record.* INTO v_existing_command FROM public.property_v1_command_idempotency AS command_record
  WHERE command_record.organization_id = p_organization_id AND command_record.command = 'property_owner.archive' AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_command.resource_id = p_property_owner_id THEN RETURN true; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property owner archive' USING ERRCODE = '23505';
  END IF;
  UPDATE public.property_owners
  SET status = 'archived', archived_at = timezone('utc', now()), version = version + 1
  WHERE organization_id = p_organization_id AND id = p_property_owner_id AND version = p_expected_version AND status <> 'archived'
  RETURNING version INTO v_new_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'property owner was not found or version is stale' USING ERRCODE = '40001'; END IF;
  INSERT INTO public.property_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_version)
  VALUES (p_organization_id, 'property_owner.archive', p_property_owner_id, p_idempotency_key, v_new_version);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta)
  VALUES (p_organization_id, 'user', v_actor_membership_id, 'property_owner.archived', 'property_owner', p_property_owner_id, 'success', p_request_id, 'user_requested', jsonb_build_object('version', v_new_version, 'reason', btrim(p_reason)));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'property_owner.archived', 1, 'property-owner-v1-archive:' || p_property_owner_id::text || ':' || p_idempotency_key, jsonb_build_object('property_owner_id', p_property_owner_id, 'version', v_new_version));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_property_owner_v1(
  p_organization_id uuid,
  p_property_owner_id uuid,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing_command public.property_v1_command_idempotency%ROWTYPE;
  v_new_version integer;
BEGIN
  IF p_property_owner_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'property owner restore input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor_membership_id FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN RAISE EXCEPTION 'property owner restore is not permitted' USING ERRCODE = '42501'; END IF;
  SELECT command_record.* INTO v_existing_command FROM public.property_v1_command_idempotency AS command_record
  WHERE command_record.organization_id = p_organization_id AND command_record.command = 'property_owner.restore' AND command_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_command.resource_id = p_property_owner_id THEN RETURN true; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property owner restore' USING ERRCODE = '23505';
  END IF;
  UPDATE public.property_owners
  SET status = 'active', archived_at = NULL, version = version + 1
  WHERE organization_id = p_organization_id AND id = p_property_owner_id AND version = p_expected_version AND status = 'archived'
  RETURNING version INTO v_new_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'archived property owner was not found or version is stale' USING ERRCODE = '40001'; END IF;
  INSERT INTO public.property_v1_command_idempotency (organization_id, command, resource_id, idempotency_key, result_version)
  VALUES (p_organization_id, 'property_owner.restore', p_property_owner_id, p_idempotency_key, v_new_version);
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor_membership_id, 'property_owner.restored', 'property_owner', p_property_owner_id, 'success', p_request_id, jsonb_build_object('version', v_new_version, 'status', 'active'));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'property_owner.restored', 1, 'property-owner-v1-restore:' || p_property_owner_id::text || ':' || p_idempotency_key, jsonb_build_object('property_owner_id', p_property_owner_id, 'version', v_new_version));
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.assign_property_owner_v1(
  p_organization_id uuid,
  p_property_id uuid,
  p_property_owner_id uuid,
  p_start_date date,
  p_end_date date,
  p_is_primary_contact boolean,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing public.property_ownership_periods%ROWTYPE;
  v_period_id uuid;
BEGIN
  IF p_organization_id IS NULL OR p_property_id IS NULL OR p_property_owner_id IS NULL
    OR p_start_date IS NULL OR p_end_date IS NULL OR p_start_date >= p_end_date
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'property ownership input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor_membership_id FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN RAISE EXCEPTION 'property ownership is not permitted' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.properties AS property_record WHERE property_record.organization_id = p_organization_id AND property_record.id = p_property_id AND property_record.status <> 'archived') THEN
    RAISE EXCEPTION 'property is not available for ownership assignment' USING ERRCODE = '23503';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.property_owners AS owner_record WHERE owner_record.organization_id = p_organization_id AND owner_record.id = p_property_owner_id AND owner_record.status = 'active') THEN
    RAISE EXCEPTION 'property owner is not active' USING ERRCODE = '23503';
  END IF;
  SELECT period.* INTO v_existing FROM public.property_ownership_periods AS period
  WHERE period.organization_id = p_organization_id AND period.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.property_id = p_property_id AND v_existing.property_owner_id = p_property_owner_id
      AND v_existing.start_date = p_start_date AND v_existing.end_date = p_end_date
      AND v_existing.is_primary_contact = p_is_primary_contact THEN RETURN v_existing.id; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different ownership period' USING ERRCODE = '23505';
  END IF;
  INSERT INTO public.property_ownership_periods (organization_id, property_id, property_owner_id, start_date, end_date, is_primary_contact, idempotency_key)
  VALUES (p_organization_id, p_property_id, p_property_owner_id, p_start_date, p_end_date, coalesce(p_is_primary_contact, false), p_idempotency_key)
  RETURNING id INTO v_period_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor_membership_id, 'property_owner.assignment_created', 'property_ownership_period', v_period_id, 'success', p_request_id, jsonb_build_object('property_id', p_property_id, 'property_owner_id', p_property_owner_id, 'start_date', p_start_date, 'end_date', p_end_date, 'is_primary_contact', coalesce(p_is_primary_contact, false)));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'property_owner.assignment_created', 1, 'property-owner-assignment-v1:' || v_period_id::text, jsonb_build_object('ownership_period_id', v_period_id, 'property_id', p_property_id, 'property_owner_id', p_property_owner_id));
  RETURN v_period_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.register_property_image_v1(
  p_organization_id uuid,
  p_property_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_width_px integer,
  p_height_px integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing public.property_images%ROWTYPE;
  v_image_id uuid;
  v_expected_prefix text;
  v_extension text;
  v_active_count integer;
BEGIN
  IF p_organization_id IS NULL OR p_property_id IS NULL
    OR p_storage_path IS NULL OR p_mime_type IS NULL
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'property image input is incomplete' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor_membership_id FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
    AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN RAISE EXCEPTION 'property image registration is not permitted' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.properties AS property_record WHERE property_record.organization_id = p_organization_id AND property_record.id = p_property_id AND property_record.status <> 'archived') THEN
    RAISE EXCEPTION 'property is not available for image registration' USING ERRCODE = '23503';
  END IF;
  v_expected_prefix := p_organization_id::text || '/' || p_property_id::text || '/';
  IF lower(p_storage_path) <> p_storage_path OR left(p_storage_path, char_length(v_expected_prefix)) <> v_expected_prefix
    OR p_storage_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$' THEN
    RAISE EXCEPTION 'property image storage path is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_mime_type NOT IN ('image/jpeg', 'image/png', 'image/webp') THEN
    RAISE EXCEPTION 'property image mime type is invalid' USING ERRCODE = '22023';
  END IF;
  v_extension := lower(substring(p_storage_path FROM '[.]([a-z0-9]+)$'));
  IF (p_mime_type = 'image/jpeg' AND v_extension NOT IN ('jpg', 'jpeg'))
    OR (p_mime_type = 'image/png' AND v_extension <> 'png')
    OR (p_mime_type = 'image/webp' AND v_extension <> 'webp') THEN
    RAISE EXCEPTION 'property image mime type does not match its extension' USING ERRCODE = '22023';
  END IF;
  IF p_byte_size IS NULL OR p_byte_size < 1 OR p_byte_size > 10485760 THEN
    RAISE EXCEPTION 'property image size is invalid' USING ERRCODE = '22023';
  END IF;
  IF (p_width_px IS NULL) <> (p_height_px IS NULL)
    OR p_width_px IS NOT NULL AND (p_width_px < 1 OR p_width_px > 20000)
    OR p_height_px IS NOT NULL AND (p_height_px < 1 OR p_height_px > 20000) THEN
    RAISE EXCEPTION 'property image dimensions are invalid' USING ERRCODE = '22023';
  END IF;

  SELECT image_record.* INTO v_existing FROM public.property_images AS image_record
  WHERE image_record.organization_id = p_organization_id AND image_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.property_id = p_property_id AND v_existing.storage_path = p_storage_path
      AND v_existing.mime_type = p_mime_type AND v_existing.byte_size = p_byte_size AND v_existing.width_px = p_width_px AND v_existing.height_px = p_height_px
      AND v_existing.status = 'active' THEN RETURN v_existing.id; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property image' USING ERRCODE = '23505';
  END IF;
  SELECT count(*)::integer INTO v_active_count FROM public.property_images AS image_record
  WHERE image_record.organization_id = p_organization_id AND image_record.property_id = p_property_id AND image_record.status = 'active';
  IF v_active_count >= 20 THEN RAISE EXCEPTION 'property image limit reached' USING ERRCODE = '22023'; END IF;

  INSERT INTO public.property_images (organization_id, property_id, storage_path, mime_type, byte_size, width_px, height_px, idempotency_key, created_by_membership_id)
  VALUES (p_organization_id, p_property_id, p_storage_path, p_mime_type, p_byte_size, p_width_px, p_height_px, p_idempotency_key, v_actor_membership_id)
  RETURNING id INTO v_image_id;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, after_delta)
  VALUES (p_organization_id, 'user', v_actor_membership_id, 'property.image_registered', 'property_image', v_image_id, 'success', p_request_id, jsonb_build_object('property_id', p_property_id, 'mime_type', p_mime_type, 'storage_bucket', 'property-images'));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'property.image.registered', 1, 'property-image-v1:' || v_image_id::text, jsonb_build_object('property_image_id', v_image_id, 'property_id', p_property_id, 'storage_path', p_storage_path));
  RETURN v_image_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_property_images_v1(
  p_organization_id uuid,
  p_property_id uuid
)
RETURNS TABLE (id uuid, storage_bucket text, storage_path text, mime_type text, byte_size bigint, width_px integer, height_px integer, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.organization_memberships AS membership WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active') THEN
    RAISE EXCEPTION 'property image read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT image_record.id, image_record.storage_bucket, image_record.storage_path, image_record.mime_type, image_record.byte_size, image_record.width_px, image_record.height_px, image_record.created_at
  FROM public.property_images AS image_record
  WHERE image_record.organization_id = p_organization_id AND image_record.property_id = p_property_id AND image_record.status = 'active'
  ORDER BY image_record.created_at ASC, image_record.id ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_property_image_v1(
  p_organization_id uuid,
  p_property_image_id uuid,
  p_reason text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_updated_count integer;
BEGIN
  IF p_property_image_id IS NULL OR p_reason IS NULL OR char_length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'property image archive input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor_membership_id FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN RAISE EXCEPTION 'property image archive is not permitted' USING ERRCODE = '42501'; END IF;
  UPDATE public.property_images
  SET status = 'archived', archived_at = timezone('utc', now()), archived_by_membership_id = v_actor_membership_id
  WHERE organization_id = p_organization_id AND id = p_property_image_id AND status = 'active';
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count = 0 THEN
    IF EXISTS (SELECT 1 FROM public.property_images WHERE organization_id = p_organization_id AND id = p_property_image_id AND status = 'archived') THEN RETURN true; END IF;
    RAISE EXCEPTION 'property image was not found' USING ERRCODE = '23503';
  END IF;
  INSERT INTO public.audit_events (organization_id, actor_type, actor_membership_id, action, resource_type, resource_id, outcome, request_id, reason_code, after_delta)
  VALUES (p_organization_id, 'user', v_actor_membership_id, 'property.image_archived', 'property_image', p_property_image_id, 'success', p_request_id, 'user_requested', jsonb_build_object('reason', btrim(p_reason)));
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'property.image.archived', 1, 'property-image-v1-archive:' || p_property_image_id::text, jsonb_build_object('property_image_id', p_property_image_id));
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.create_property_v1(uuid, text, text, text, text, text, text, integer, integer, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_properties_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_property_v1(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.archive_property_v1(uuid, uuid, text, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.restore_property_v1(uuid, uuid, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_property_owner_v1(uuid, text, text, text, text, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_property_owners_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_property_owner_v1(uuid, uuid, text, text, text, text, text, text, text, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.archive_property_owner_v1(uuid, uuid, text, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.restore_property_owner_v1(uuid, uuid, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assign_property_owner_v1(uuid, uuid, uuid, date, date, boolean, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.register_property_image_v1(uuid, uuid, text, text, bigint, integer, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_property_images_v1(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.archive_property_image_v1(uuid, uuid, text, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_property_v1(uuid, text, text, text, text, text, text, integer, integer, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_properties_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_property_v1(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.archive_property_v1(uuid, uuid, text, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_property_v1(uuid, uuid, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_property_owner_v1(uuid, text, text, text, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_property_owners_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_property_owner_v1(uuid, uuid, text, text, text, text, text, text, text, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.archive_property_owner_v1(uuid, uuid, text, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_property_owner_v1(uuid, uuid, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assign_property_owner_v1(uuid, uuid, uuid, date, date, boolean, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_property_image_v1(uuid, uuid, text, text, bigint, integer, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_property_images_v1(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.archive_property_image_v1(uuid, uuid, text, uuid) TO authenticated;
