-- Performance Optimization Migration
-- Adds count RPCs for dashboard metrics and pagination limits to list RPCs

BEGIN;

-- ============================================================
-- 1. Dashboard Count RPCs (avoid fetching all rows)
-- ============================================================

-- Count all properties (including inactive/archived)
CREATE OR REPLACE FUNCTION public.count_all_properties(p_organization_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.properties
  WHERE organization_id = p_organization_id;
$$;

GRANT EXECUTE ON FUNCTION public.count_all_properties(uuid) TO authenticated;

-- Count active properties
CREATE OR REPLACE FUNCTION public.count_active_properties(p_organization_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.properties
  WHERE organization_id = p_organization_id
    AND status = 'active'
    AND archived_at IS NULL;
$$;

GRANT EXECUTE ON FUNCTION public.count_active_properties(uuid) TO authenticated;

-- Count total clients
CREATE OR REPLACE FUNCTION public.count_clients(p_organization_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.clients
  WHERE organization_id = p_organization_id
    AND archived_at IS NULL;
$$;

GRANT EXECUTE ON FUNCTION public.count_clients(uuid) TO authenticated;

-- Count active leads (CRM)
CREATE OR REPLACE FUNCTION public.count_active_leads(p_organization_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.leads
  WHERE organization_id = p_organization_id
    AND status NOT IN ('won', 'lost')
    AND archived_at IS NULL;
$$;

GRANT EXECUTE ON FUNCTION public.count_active_leads(uuid) TO authenticated;

-- Count pending approval requests
CREATE OR REPLACE FUNCTION public.count_pending_approvals(p_organization_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.approval_requests
  WHERE organization_id = p_organization_id
    AND status = 'pending';
$$;

GRANT EXECUTE ON FUNCTION public.count_pending_approvals(uuid) TO authenticated;

-- Count availability blocks
CREATE OR REPLACE FUNCTION public.count_availability_blocks(p_organization_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.availability_blocks
  WHERE organization_id = p_organization_id;
$$;

GRANT EXECUTE ON FUNCTION public.count_availability_blocks(uuid) TO authenticated;

-- ============================================================
-- 2. Paginated List RPCs (add limits to unbounded queries)
-- ============================================================

-- Paginated list_properties_v1
CREATE OR REPLACE FUNCTION public.list_properties_v1_paginated(
  p_organization_id uuid,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  code text,
  name text,
  timezone text,
  status text,
  address text,
  city text,
  unit_label text,
  bedrooms integer,
  max_guests integer,
  operational_notes text,
  created_at timestamptz,
  updated_at timestamptz,
  bathrooms integer,
  area_sqm numeric,
  floor text,
  furnished boolean,
  district text,
  rent_daily boolean,
  rent_weekly boolean,
  rent_monthly boolean,
  daily_price numeric,
  weekly_price numeric,
  monthly_price numeric,
  currency text,
  amenities text[],
  minimum_stay_nights integer,
  marketing_description text,
  owner_display_name text,
  image_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p.id,
    p.code,
    p.name,
    p.timezone,
    p.status,
    p.address,
    p.city,
    p.unit_label,
    p.bedrooms,
    p.max_guests,
    p.operational_notes,
    p.created_at,
    p.updated_at,
    p.bathrooms,
    p.area_sqm,
    p.floor,
    p.furnished,
    p.district,
    p.rent_daily,
    p.rent_weekly,
    p.rent_monthly,
    p.daily_price,
    p.weekly_price,
    p.monthly_price,
    p.currency,
    p.amenities,
    p.minimum_stay_nights,
    p.marketing_description,
    po.display_name AS owner_display_name,
    (SELECT count(*) FROM public.property_images pi WHERE pi.property_id = p.id) AS image_count
  FROM public.properties p
  LEFT JOIN public.property_ownership_periods pop ON pop.organization_id = p.organization_id AND pop.property_id = p.id
  LEFT JOIN public.property_owners po ON po.organization_id = p.organization_id AND po.id = pop.property_owner_id
  WHERE p.organization_id = p_organization_id
    AND p.status = 'active'
    AND p.archived_at IS NULL
  ORDER BY p.created_at DESC
  LIMIT p_limit
  OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.list_properties_v1_paginated(uuid, integer, integer) TO authenticated;

-- Paginated list_clients_v1
CREATE OR REPLACE FUNCTION public.list_clients_v1_paginated(
  p_organization_id uuid,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  display_name text,
  phone text,
  whatsapp text,
  email text,
  nationality text,
  preferred_language text,
  notes text,
  source_lead_id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  normalized_phone text,
  normalized_email text,
  duplicate_warnings jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH lead_stats AS (
    SELECT
      l.id AS lead_id,
      (SELECT count(*) FROM public.crm_activities ca WHERE ca.lead_id = l.id) AS activity_count,
      (SELECT count(*) FROM public.crm_follow_ups cf WHERE cf.lead_id = l.id AND cf.status = 'pending') AS pending_follow_up_count
    FROM public.leads l
    WHERE l.organization_id = p_organization_id
      AND l.archived_at IS NULL
  ),
  client_duplicates AS (
    SELECT
      c.id,
      CASE
        WHEN c.normalized_phone IS NOT NULL AND EXISTS (
          SELECT 1 FROM public.clients c2
          WHERE c2.organization_id = c.organization_id
            AND c2.id != c.id
            AND c2.normalized_phone = c.normalized_phone
            AND c2.archived_at IS NULL
        ) THEN jsonb_build_array('duplicate_phone')
        WHEN c.normalized_email IS NOT NULL AND EXISTS (
          SELECT 1 FROM public.clients c2
          WHERE c2.organization_id = c.organization_id
            AND c2.id != c.id
            AND c2.normalized_email = c.normalized_email
            AND c2.archived_at IS NULL
        ) THEN jsonb_build_array('duplicate_email')
        ELSE NULL
      END AS warnings
    FROM public.clients c
    WHERE c.organization_id = p_organization_id
      AND c.archived_at IS NULL
  )
  SELECT
    c.id,
    c.display_name,
    c.phone,
    c.whatsapp,
    c.email,
    c.nationality,
    c.preferred_language,
    c.notes,
    c.source_lead_id,
    c.created_at,
    c.updated_at,
    c.normalized_phone,
    c.normalized_email,
    cd.warnings AS duplicate_warnings
  FROM public.clients c
  LEFT JOIN client_duplicates cd ON cd.id = c.id
  WHERE c.organization_id = p_organization_id
    AND c.archived_at IS NULL
  ORDER BY c.created_at DESC
  LIMIT p_limit
  OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.list_clients_v1_paginated(uuid, integer, integer) TO authenticated;

-- Paginated list_leads_v1
CREATE OR REPLACE FUNCTION public.list_leads_v1_paginated(
  p_organization_id uuid,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  title text,
  name text,
  phone text,
  whatsapp text,
  email text,
  source text,
  status text,
  requested_area text,
  requested_check_in date,
  requested_check_out date,
  guests integer,
  bedrooms integer,
  budget_text text,
  notes text,
  next_follow_up_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  converted_client_id uuid,
  activity_count bigint,
  pending_follow_up_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    l.id,
    l.title,
    l.name,
    l.phone,
    l.whatsapp,
    l.email,
    l.source,
    l.status,
    l.requested_area,
    l.requested_check_in,
    l.requested_check_out,
    l.guests,
    l.bedrooms,
    l.budget_text,
    l.notes,
    l.next_follow_up_at,
    l.created_at,
    l.updated_at,
    l.converted_client_id,
    (SELECT count(*) FROM public.crm_activities ca WHERE ca.lead_id = l.id) AS activity_count,
    (SELECT count(*) FROM public.crm_follow_ups cf WHERE cf.lead_id = l.id AND cf.status = 'pending') AS pending_follow_up_count
  FROM public.leads l
  WHERE l.organization_id = p_organization_id
    AND l.archived_at IS NULL
  ORDER BY l.created_at DESC
  LIMIT p_limit
  OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.list_leads_v1_paginated(uuid, integer, integer) TO authenticated;

-- Paginated list_availability_blocks
CREATE OR REPLACE FUNCTION public.list_availability_blocks_paginated(
  p_organization_id uuid,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  property_id uuid,
  property_code text,
  property_name text,
  start_date date,
  end_date date,
  block_type text,
  reason text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ab.id,
    ab.property_id,
    p.code AS property_code,
    p.name AS property_name,
    ab.start_date,
    ab.end_date,
    ab.block_type,
    ab.reason,
    ab.created_at
  FROM public.availability_blocks ab
  JOIN public.properties p ON p.organization_id = ab.organization_id AND p.id = ab.property_id
  WHERE ab.organization_id = p_organization_id
  ORDER BY ab.start_date DESC
  LIMIT p_limit
  OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.list_availability_blocks_paginated(uuid, integer, integer) TO authenticated;

-- Paginated list_commercial_booking_work_queue
CREATE OR REPLACE FUNCTION public.list_commercial_booking_work_queue_paginated(
  p_organization_id uuid,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  property_id uuid,
  property_code text,
  property_name text,
  client_id uuid,
  client_display_name text,
  status text,
  check_in date,
  check_out date,
  agreed_total_amount_minor bigint,
  currency text,
  commercial_completion_status text,
  created_at timestamptz,
  updated_at timestamptz,
  has_amendment boolean,
  has_cancellation boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    b.id,
    b.property_id,
    p.code AS property_code,
    p.name AS property_name,
    b.client_id,
    c.display_name AS client_display_name,
    b.status,
    b.check_in,
    b.check_out,
    b.agreed_total_amount_minor,
    b.currency,
    b.commercial_completion_status,
    b.created_at,
    b.updated_at,
    false AS has_amendment,
    false AS has_cancellation
  FROM public.bookings b
  JOIN public.properties p ON p.organization_id = b.organization_id AND p.id = b.property_id
  LEFT JOIN public.clients c ON c.organization_id = b.organization_id AND c.id = b.client_id
  WHERE b.organization_id = p_organization_id
  ORDER BY b.created_at DESC
  LIMIT p_limit
  OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.list_commercial_booking_work_queue_paginated(uuid, integer, integer) TO authenticated;

-- Paginated list_fleet_vehicles
CREATE OR REPLACE FUNCTION public.list_fleet_vehicles_paginated(
  p_organization_id uuid,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  display_name text,
  vehicle_type text,
  registration_code text,
  passenger_capacity smallint,
  status text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    fv.id,
    fv.display_name,
    fv.vehicle_type,
    fv.registration_code,
    fv.passenger_capacity,
    fv.status,
    fv.created_at,
    fv.updated_at
  FROM public.fleet_vehicles fv
  WHERE fv.organization_id = p_organization_id
    AND fv.status != 'inactive'
  ORDER BY fv.created_at DESC
  LIMIT p_limit
  OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.list_fleet_vehicles_paginated(uuid, integer, integer) TO authenticated;

-- Paginated list_fleet_drivers
CREATE OR REPLACE FUNCTION public.list_fleet_drivers_paginated(
  p_organization_id uuid,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  display_name text,
  phone_e164 text,
  status text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    fd.id,
    fd.display_name,
    fd.phone_e164,
    fd.status,
    fd.created_at,
    fd.updated_at
  FROM public.fleet_drivers fd
  WHERE fd.organization_id = p_organization_id
    AND fd.status != 'inactive'
  ORDER BY fd.created_at DESC
  LIMIT p_limit
  OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.list_fleet_drivers_paginated(uuid, integer, integer) TO authenticated;

-- Paginated list_property_owners_v1
CREATE OR REPLACE FUNCTION public.list_property_owners_v1_paginated(
  p_organization_id uuid,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  display_name text,
  phone text,
  whatsapp text,
  email text,
  preferred_contact_method text,
  notes text,
  status text,
  created_at timestamptz,
  updated_at timestamptz,
  property_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    po.id,
    po.display_name,
    po.phone,
    po.whatsapp,
    po.email,
    po.preferred_contact_method,
    po.notes,
    po.status,
    po.created_at,
    po.updated_at,
    (SELECT count(*) FROM public.property_ownership_periods pop
     WHERE pop.organization_id = po.organization_id
       AND pop.property_owner_id = po.id
       AND pop.end_date >= CURRENT_DATE) AS property_count
  FROM public.property_owners po
  WHERE po.organization_id = p_organization_id
    AND po.archived_at IS NULL
  ORDER BY po.created_at DESC
  LIMIT p_limit
  OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.list_property_owners_v1_paginated(uuid, integer, integer) TO authenticated;

-- ============================================================
-- 3. Batch Activity/Follow-up Loading (fix N+1 on leads page)
-- ============================================================

-- Batch load activities for multiple leads
CREATE OR REPLACE FUNCTION public.list_lead_activities_batch(
  p_organization_id uuid,
  p_lead_ids uuid[]
)
RETURNS TABLE (
  lead_id uuid,
  id uuid,
  activity_type text,
  content text,
  metadata jsonb,
  created_at timestamptz,
  created_by_display_name text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ca.lead_id,
    ca.id,
    ca.activity_type,
    ca.content,
    NULL::jsonb AS metadata,
    ca.created_at,
    p.display_name AS created_by_display_name
  FROM public.crm_activities ca
  LEFT JOIN public.profiles p ON p.id = ca.actor_membership_id
  WHERE ca.organization_id = p_organization_id
    AND ca.lead_id = ANY(p_lead_ids)
  ORDER BY ca.created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.list_lead_activities_batch(uuid, uuid[]) TO authenticated;

-- Batch load follow-ups for multiple leads
CREATE OR REPLACE FUNCTION public.list_lead_follow_ups_batch(
  p_organization_id uuid,
  p_lead_ids uuid[]
)
RETURNS TABLE (
  lead_id uuid,
  id uuid,
  status text,
  scheduled_at timestamptz,
  completed_at timestamptz,
  notes text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    cf.lead_id,
    cf.id,
    cf.status,
    cf.due_at AS scheduled_at,
    cf.completed_at,
    cf.note AS notes,
    cf.created_at
  FROM public.crm_follow_ups cf
  WHERE cf.organization_id = p_organization_id
    AND cf.lead_id = ANY(p_lead_ids)
  ORDER BY cf.due_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.list_lead_follow_ups_batch(uuid, uuid[]) TO authenticated;

-- Batch load property images for multiple properties
CREATE OR REPLACE FUNCTION public.list_property_images_batch(
  p_organization_id uuid,
  p_property_ids uuid[]
)
RETURNS TABLE (
  property_id uuid,
  id uuid,
  storage_path text,
  mime_type text,
  byte_size bigint,
  width_px integer,
  height_px integer,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    pi.property_id,
    pi.id,
    pi.storage_path,
    pi.mime_type,
    pi.byte_size,
    pi.width_px,
    pi.height_px,
    pi.created_at
  FROM public.property_images pi
  WHERE pi.organization_id = p_organization_id
    AND pi.property_id = ANY(p_property_ids)
    AND pi.status = 'active'
  ORDER BY pi.created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.list_property_images_batch(uuid, uuid[]) TO authenticated;

COMMIT;
