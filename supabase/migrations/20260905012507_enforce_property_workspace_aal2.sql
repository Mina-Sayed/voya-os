-- Workspace tenant data requires a verified MFA AAL2 session at the database
-- boundary. Keep onboarding/invitation RPCs outside this migration: they are
-- pre-membership flows with their own explicit authorization contracts.

CREATE OR REPLACE FUNCTION public.require_workspace_aal2_v1()
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' THEN
    RAISE EXCEPTION 'MFA AAL2 is required for workspace data' USING ERRCODE = '42501';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.require_workspace_aal2_v1() FROM PUBLIC, anon, authenticated, service_role;

-- Preserve the existing implementations under non-public names. The public
-- signatures remain stable for Server Actions and PostgREST callers, while
-- every property/owner/image entry point passes through the same AAL2 gate.

ALTER FUNCTION public.create_property(uuid, text, text, text, text, uuid)
  RENAME TO create_property_without_workspace_aal2;
ALTER FUNCTION public.list_properties(uuid)
  RENAME TO list_properties_without_workspace_aal2;
ALTER FUNCTION public.create_property_v1(uuid, text, text, text, text, text, text, integer, integer, text, text, uuid)
  RENAME TO create_property_v1_without_workspace_aal2;
ALTER FUNCTION public.list_properties_v1(uuid)
  RENAME TO list_properties_v1_without_workspace_aal2;
ALTER FUNCTION public.update_property_v1(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, text, uuid)
  RENAME TO update_property_v1_without_workspace_aal2;
ALTER FUNCTION public.archive_property_v1(uuid, uuid, text, integer, text, uuid)
  RENAME TO archive_property_v1_without_workspace_aal2;
ALTER FUNCTION public.restore_property_v1(uuid, uuid, integer, text, uuid)
  RENAME TO restore_property_v1_without_workspace_aal2;
ALTER FUNCTION public.create_property_v1(uuid, text, text, text, text, text, text, integer, integer, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, text, uuid)
  RENAME TO create_property_v1_without_workspace_aal2;
ALTER FUNCTION public.list_properties_v1_extended(uuid)
  RENAME TO list_properties_v1_extended_without_workspace_aal2;
ALTER FUNCTION public.update_property_v1(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, integer, text, uuid)
  RENAME TO update_property_v1_without_workspace_aal2;
ALTER FUNCTION public.create_property_owner(uuid, text, text, uuid)
  RENAME TO create_property_owner_without_workspace_aal2;
ALTER FUNCTION public.list_property_owners(uuid)
  RENAME TO list_property_owners_without_workspace_aal2;
ALTER FUNCTION public.create_property_owner_v1(uuid, text, text, text, text, text, text, text, uuid)
  RENAME TO create_property_owner_v1_without_workspace_aal2;
ALTER FUNCTION public.list_property_owners_v1(uuid)
  RENAME TO list_property_owners_v1_without_workspace_aal2;
ALTER FUNCTION public.update_property_owner_v1(uuid, uuid, text, text, text, text, text, text, text, integer, text, uuid)
  RENAME TO update_property_owner_v1_without_workspace_aal2;
ALTER FUNCTION public.archive_property_owner_v1(uuid, uuid, text, integer, text, uuid)
  RENAME TO archive_property_owner_v1_without_workspace_aal2;
ALTER FUNCTION public.restore_property_owner_v1(uuid, uuid, integer, text, uuid)
  RENAME TO restore_property_owner_v1_without_workspace_aal2;
ALTER FUNCTION public.assign_property_owner_v1(uuid, uuid, uuid, date, date, boolean, text, uuid)
  RENAME TO assign_property_owner_v1_without_workspace_aal2;
ALTER FUNCTION public.register_property_image_v1(uuid, uuid, text, text, bigint, integer, integer, text, uuid)
  RENAME TO register_property_image_v1_without_workspace_aal2;
ALTER FUNCTION public.list_property_images_v1(uuid, uuid)
  RENAME TO list_property_images_v1_without_workspace_aal2;
ALTER FUNCTION public.archive_property_image_v1(uuid, uuid, text, uuid)
  RENAME TO archive_property_image_v1_without_workspace_aal2;

REVOKE ALL ON FUNCTION public.create_property_without_workspace_aal2(uuid, text, text, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_properties_without_workspace_aal2(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_property_v1_without_workspace_aal2(uuid, text, text, text, text, text, text, integer, integer, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_properties_v1_without_workspace_aal2(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.update_property_v1_without_workspace_aal2(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.archive_property_v1_without_workspace_aal2(uuid, uuid, text, integer, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.restore_property_v1_without_workspace_aal2(uuid, uuid, integer, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_property_v1_without_workspace_aal2(uuid, text, text, text, text, text, text, integer, integer, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_properties_v1_extended_without_workspace_aal2(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.update_property_v1_without_workspace_aal2(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, integer, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_property_owner_without_workspace_aal2(uuid, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_property_owners_without_workspace_aal2(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_property_owner_v1_without_workspace_aal2(uuid, text, text, text, text, text, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_property_owners_v1_without_workspace_aal2(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.update_property_owner_v1_without_workspace_aal2(uuid, uuid, text, text, text, text, text, text, text, integer, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.archive_property_owner_v1_without_workspace_aal2(uuid, uuid, text, integer, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.restore_property_owner_v1_without_workspace_aal2(uuid, uuid, integer, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.assign_property_owner_v1_without_workspace_aal2(uuid, uuid, uuid, date, date, boolean, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.register_property_image_v1_without_workspace_aal2(uuid, uuid, text, text, bigint, integer, integer, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_property_images_v1_without_workspace_aal2(uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.archive_property_image_v1_without_workspace_aal2(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_property(
  p_organization_id uuid,
  p_code text,
  p_name text,
  p_timezone text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.create_property_without_workspace_aal2(
    p_organization_id, p_code, p_name, p_timezone, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_properties(p_organization_id uuid)
RETURNS TABLE (id uuid, code text, name text, timezone text, status text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_properties_without_workspace_aal2(p_organization_id);
END;
$$;

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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.create_property_v1_without_workspace_aal2(
    p_organization_id, p_code, p_name, p_timezone, p_address, p_city,
    p_unit_label, p_bedrooms, p_max_guests, p_operational_notes,
    p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_properties_v1(p_organization_id uuid)
RETURNS TABLE (
  id uuid, code text, name text, timezone text, address text, city text,
  unit_label text, bedrooms integer, max_guests integer, operational_notes text,
  status text, version integer, created_at timestamptz, updated_at timestamptz,
  archived_at timestamptz, current_property_owner_id uuid,
  current_property_owner_name text, image_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_properties_v1_without_workspace_aal2(p_organization_id);
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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.update_property_v1_without_workspace_aal2(
    p_organization_id, p_property_id, p_code, p_name, p_timezone, p_address,
    p_city, p_unit_label, p_bedrooms, p_max_guests, p_operational_notes,
    p_status, p_expected_version, p_idempotency_key, p_request_id
  );
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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.archive_property_v1_without_workspace_aal2(
    p_organization_id, p_property_id, p_reason, p_expected_version,
    p_idempotency_key, p_request_id
  );
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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.restore_property_v1_without_workspace_aal2(
    p_organization_id, p_property_id, p_expected_version,
    p_idempotency_key, p_request_id
  );
END;
$$;

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
  p_bathrooms integer,
  p_area_sqm numeric,
  p_floor text,
  p_furnished boolean,
  p_district text,
  p_rent_daily boolean,
  p_rent_weekly boolean,
  p_rent_monthly boolean,
  p_daily_price numeric,
  p_weekly_price numeric,
  p_monthly_price numeric,
  p_currency text,
  p_amenities text[],
  p_minimum_stay_nights integer,
  p_marketing_description text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.create_property_v1_without_workspace_aal2(
    p_organization_id, p_code, p_name, p_timezone, p_address, p_city,
    p_unit_label, p_bedrooms, p_max_guests, p_operational_notes, p_bathrooms,
    p_area_sqm, p_floor, p_furnished, p_district, p_rent_daily, p_rent_weekly,
    p_rent_monthly, p_daily_price, p_weekly_price, p_monthly_price, p_currency,
    p_amenities, p_minimum_stay_nights, p_marketing_description,
    p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_properties_v1_extended(p_organization_id uuid)
RETURNS TABLE (
  id uuid, code text, name text, timezone text, address text, city text,
  unit_label text, bedrooms integer, max_guests integer, operational_notes text,
  bathrooms integer, area_sqm numeric, floor text, furnished boolean,
  district text, rent_daily boolean, rent_weekly boolean, rent_monthly boolean,
  daily_price numeric, weekly_price numeric, monthly_price numeric, currency text,
  amenities text[], minimum_stay_nights integer, marketing_description text,
  status text, version integer, created_at timestamptz, updated_at timestamptz,
  archived_at timestamptz, current_property_owner_id uuid,
  current_property_owner_name text, image_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_properties_v1_extended_without_workspace_aal2(p_organization_id);
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
  p_bathrooms integer,
  p_area_sqm numeric,
  p_floor text,
  p_furnished boolean,
  p_district text,
  p_rent_daily boolean,
  p_rent_weekly boolean,
  p_rent_monthly boolean,
  p_daily_price numeric,
  p_weekly_price numeric,
  p_monthly_price numeric,
  p_currency text,
  p_amenities text[],
  p_minimum_stay_nights integer,
  p_marketing_description text,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.update_property_v1_without_workspace_aal2(
    p_organization_id, p_property_id, p_code, p_name, p_timezone, p_address,
    p_city, p_unit_label, p_bedrooms, p_max_guests, p_operational_notes,
    p_status, p_bathrooms, p_area_sqm, p_floor, p_furnished, p_district,
    p_rent_daily, p_rent_weekly, p_rent_monthly, p_daily_price, p_weekly_price,
    p_monthly_price, p_currency, p_amenities, p_minimum_stay_nights,
    p_marketing_description, p_expected_version, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.create_property_owner(
  p_organization_id uuid,
  p_display_name text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.create_property_owner_without_workspace_aal2(
    p_organization_id, p_display_name, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_property_owners(p_organization_id uuid)
RETURNS TABLE (id uuid, display_name text, status text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_property_owners_without_workspace_aal2(p_organization_id);
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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.create_property_owner_v1_without_workspace_aal2(
    p_organization_id, p_display_name, p_phone, p_whatsapp, p_email,
    p_preferred_contact_method, p_notes, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_property_owners_v1(p_organization_id uuid)
RETURNS TABLE (
  id uuid, display_name text, phone text, whatsapp text, email text,
  preferred_contact_method text, notes text, status text, version integer,
  created_at timestamptz, archived_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_property_owners_v1_without_workspace_aal2(p_organization_id);
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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.update_property_owner_v1_without_workspace_aal2(
    p_organization_id, p_property_owner_id, p_display_name, p_phone,
    p_whatsapp, p_email, p_preferred_contact_method, p_notes, p_status,
    p_expected_version, p_idempotency_key, p_request_id
  );
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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.archive_property_owner_v1_without_workspace_aal2(
    p_organization_id, p_property_owner_id, p_reason, p_expected_version,
    p_idempotency_key, p_request_id
  );
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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.restore_property_owner_v1_without_workspace_aal2(
    p_organization_id, p_property_owner_id, p_expected_version,
    p_idempotency_key, p_request_id
  );
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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.assign_property_owner_v1_without_workspace_aal2(
    p_organization_id, p_property_id, p_property_owner_id, p_start_date,
    p_end_date, p_is_primary_contact, p_idempotency_key, p_request_id
  );
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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.register_property_image_v1_without_workspace_aal2(
    p_organization_id, p_property_id, p_storage_path, p_mime_type,
    p_byte_size, p_width_px, p_height_px, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_property_images_v1(
  p_organization_id uuid,
  p_property_id uuid
)
RETURNS TABLE (
  id uuid, storage_bucket text, storage_path text, mime_type text,
  byte_size bigint, width_px integer, height_px integer, created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_property_images_v1_without_workspace_aal2(
    p_organization_id, p_property_id
  );
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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.archive_property_image_v1_without_workspace_aal2(
    p_organization_id, p_property_image_id, p_reason, p_request_id
  );
END;
$$;

-- New functions default to PUBLIC EXECUTE; undo that default and expose only
-- the stable authenticated APIs. The renamed implementations are internal
-- helpers and must not become an alternate public path.

REVOKE ALL ON FUNCTION public.create_property(uuid, text, text, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_properties(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_property_v1(uuid, text, text, text, text, text, text, integer, integer, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_properties_v1(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_property_v1(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.archive_property_v1(uuid, uuid, text, integer, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.restore_property_v1(uuid, uuid, integer, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_property_v1(uuid, text, text, text, text, text, text, integer, integer, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_properties_v1_extended(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_property_v1(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, integer, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_property_owner(uuid, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_property_owners(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_property_owner_v1(uuid, text, text, text, text, text, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_property_owners_v1(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_property_owner_v1(uuid, uuid, text, text, text, text, text, text, text, integer, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.archive_property_owner_v1(uuid, uuid, text, integer, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.restore_property_owner_v1(uuid, uuid, integer, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.assign_property_owner_v1(uuid, uuid, uuid, date, date, boolean, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.register_property_image_v1(uuid, uuid, text, text, bigint, integer, integer, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_property_images_v1(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.archive_property_image_v1(uuid, uuid, text, uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_property(uuid, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_properties(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_property_v1(uuid, text, text, text, text, text, text, integer, integer, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_properties_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_property_v1(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.archive_property_v1(uuid, uuid, text, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_property_v1(uuid, uuid, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_property_v1(uuid, text, text, text, text, text, text, integer, integer, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_properties_v1_extended(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_property_v1(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_property_owner(uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_property_owners(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_property_owner_v1(uuid, text, text, text, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_property_owners_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_property_owner_v1(uuid, uuid, text, text, text, text, text, text, text, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.archive_property_owner_v1(uuid, uuid, text, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_property_owner_v1(uuid, uuid, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assign_property_owner_v1(uuid, uuid, uuid, date, date, boolean, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_property_image_v1(uuid, uuid, text, text, bigint, integer, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_property_images_v1(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.archive_property_image_v1(uuid, uuid, text, uuid) TO authenticated;
