-- Bound workspace list payloads with keyset pagination and batch lead details
-- and property image metadata into one RPC per page.

CREATE OR REPLACE FUNCTION public.list_leads_v1_page(
  p_organization_id uuid, p_after_created_at timestamptz DEFAULT NULL,
  p_after_id uuid DEFAULT NULL, p_limit integer DEFAULT 51
)
RETURNS TABLE (
  id uuid, name text, phone text, whatsapp text, email text, normalized_phone text,
  normalized_email text, source text, status text, assigned_membership_id uuid,
  requested_area text, requested_check_in date, requested_check_out date,
  guests integer, bedrooms integer, budget_text text, notes text,
  next_follow_up_at timestamptz, version integer, converted_client_id uuid,
  created_at timestamptz, updated_at timestamptz, archived_at timestamptz,
  duplicate_warning boolean, ai_unverified boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_role text; v_member uuid;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF (p_after_created_at IS NULL) <> (p_after_id IS NULL)
    OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 101 THEN
    RAISE EXCEPTION 'lead page cursor or limit is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.role, membership.id INTO v_role, v_member
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'viewer') THEN
    RAISE EXCEPTION 'lead read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT lead_record.id, coalesce(lead_record.name, lead_record.title), lead_record.phone,
    lead_record.whatsapp, lead_record.email, lead_record.normalized_phone,
    lead_record.normalized_email, lead_record.source, lead_record.status,
    lead_record.assigned_membership_id, lead_record.requested_area,
    lead_record.requested_check_in, lead_record.requested_check_out,
    lead_record.guests, lead_record.bedrooms, lead_record.budget_text, lead_record.notes,
    lead_record.next_follow_up_at, lead_record.version, lead_record.converted_client_id,
    lead_record.created_at, lead_record.updated_at, lead_record.archived_at,
    EXISTS (
      SELECT 1 FROM public.leads AS duplicate
      WHERE duplicate.organization_id = lead_record.organization_id
        AND duplicate.id <> lead_record.id AND duplicate.archived_at IS NULL
        AND ((lead_record.normalized_phone IS NOT NULL AND duplicate.normalized_phone = lead_record.normalized_phone)
          OR (lead_record.normalized_email IS NOT NULL AND duplicate.normalized_email = lead_record.normalized_email))
    ),
    lead_record.ai_unverified
  FROM public.leads AS lead_record
  WHERE lead_record.organization_id = p_organization_id
    AND (p_after_created_at IS NULL OR (lead_record.created_at, lead_record.id) < (p_after_created_at, p_after_id))
    AND (v_role IN ('owner', 'manager', 'operations', 'viewer')
      OR lead_record.assigned_membership_id IS NULL
      OR lead_record.assigned_membership_id = v_member)
  ORDER BY lead_record.created_at DESC, lead_record.id DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_lead_page_details_v1(
  p_organization_id uuid, p_lead_ids uuid[]
)
RETURNS TABLE (lead_id uuid, activities jsonb, follow_ups jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_role text; v_member uuid;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_lead_ids IS NULL OR cardinality(p_lead_ids) > 100 THEN
    RAISE EXCEPTION 'lead detail batch is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.role, membership.id INTO v_role, v_member
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'viewer') THEN
    RAISE EXCEPTION 'lead detail read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT lead_record.id,
    coalesce(activity_rows.items, '[]'::jsonb),
    coalesce(follow_up_rows.items, '[]'::jsonb)
  FROM public.leads AS lead_record
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(latest_activity.item ORDER BY latest_activity.created_at, latest_activity.id) AS items
    FROM (
      SELECT activity.id, activity.created_at, jsonb_build_object(
        'id', activity.id, 'lead_id', activity.lead_id,
        'actor_membership_id', activity.actor_membership_id,
        'activity_type', activity.activity_type, 'content', activity.content,
        'created_at', activity.created_at
      ) AS item
      FROM public.crm_activities AS activity
      WHERE activity.organization_id = p_organization_id AND activity.lead_id = lead_record.id
      ORDER BY activity.created_at DESC, activity.id DESC
      LIMIT 10
    ) AS latest_activity
  ) AS activity_rows ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(latest_follow_up.item ORDER BY latest_follow_up.due_at, latest_follow_up.id) AS items
    FROM (
      SELECT follow_up.id, follow_up.due_at, jsonb_build_object(
        'id', follow_up.id, 'lead_id', follow_up.lead_id,
        'assigned_membership_id', follow_up.assigned_membership_id,
        'due_at', follow_up.due_at, 'note', follow_up.note, 'status', follow_up.status,
        'completed_at', follow_up.completed_at,
        'completed_by_membership_id', follow_up.completed_by_membership_id,
        'created_at', follow_up.created_at
      ) AS item
      FROM public.crm_follow_ups AS follow_up
      WHERE follow_up.organization_id = p_organization_id AND follow_up.lead_id = lead_record.id
      ORDER BY follow_up.due_at, follow_up.id
      LIMIT 10
    ) AS latest_follow_up
  ) AS follow_up_rows ON true
  WHERE lead_record.organization_id = p_organization_id
    AND lead_record.id = ANY(p_lead_ids)
    AND (v_role <> 'sales_agent' OR public.crm_sales_lead_scope_allows_v1(p_organization_id, lead_record.id, v_member));
END;
$$;

CREATE OR REPLACE FUNCTION public.list_properties_v1_page(
  p_organization_id uuid, p_after_created_at timestamptz DEFAULT NULL,
  p_after_id uuid DEFAULT NULL, p_limit integer DEFAULT 51
)
RETURNS TABLE (property_data jsonb, created_at timestamptz, id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF (p_after_created_at IS NULL) <> (p_after_id IS NULL)
    OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 101 THEN
    RAISE EXCEPTION 'property page cursor or limit is invalid' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id
      AND membership.user_id = auth.uid() AND membership.status = 'active'
  ) THEN
    RAISE EXCEPTION 'property read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  WITH page AS (
    SELECT property_record.id, property_record.code, property_record.name,
      property_record.timezone, property_record.address, property_record.city,
      property_record.unit_label, property_record.bedrooms, property_record.max_guests,
      property_record.operational_notes, property_record.bathrooms, property_record.area_sqm,
      property_record.floor, property_record.furnished, property_record.district,
      property_record.rent_daily, property_record.rent_weekly, property_record.rent_monthly,
      property_record.daily_price, property_record.weekly_price, property_record.monthly_price,
      property_record.currency, property_record.amenities, property_record.minimum_stay_nights,
      property_record.marketing_description, property_record.status, property_record.version,
      property_record.created_at, property_record.updated_at, property_record.archived_at,
      current_owner.property_owner_id AS current_property_owner_id,
      current_owner.display_name AS current_property_owner_name,
      (SELECT count(*)::integer FROM public.property_images AS image
       WHERE image.organization_id = p_organization_id
         AND image.property_id = property_record.id AND image.status = 'active') AS image_count
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
      AND (p_after_created_at IS NULL
        OR (property_record.created_at, property_record.id) < (p_after_created_at, p_after_id))
    ORDER BY property_record.created_at DESC, property_record.id DESC
    LIMIT p_limit
  )
  SELECT to_jsonb(page), page.created_at, page.id FROM page;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_property_image_ids_v1(
  p_organization_id uuid, p_property_ids uuid[]
)
RETURNS TABLE (property_id uuid, image_ids uuid[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_property_ids IS NULL OR cardinality(p_property_ids) > 100 THEN
    RAISE EXCEPTION 'property image batch is invalid' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id
      AND membership.user_id = auth.uid() AND membership.status = 'active'
  ) THEN
    RAISE EXCEPTION 'property image read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT image_record.property_id, array_agg(image_record.id ORDER BY image_record.created_at, image_record.id)
  FROM public.property_images AS image_record
  WHERE image_record.organization_id = p_organization_id
    AND image_record.property_id = ANY(p_property_ids)
    AND image_record.status = 'active'
  GROUP BY image_record.property_id;
END;
$$;

REVOKE ALL ON FUNCTION public.list_leads_v1_page(uuid, timestamptz, uuid, integer) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_lead_page_details_v1(uuid, uuid[]) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_properties_v1_page(uuid, timestamptz, uuid, integer) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_property_image_ids_v1(uuid, uuid[]) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.list_leads_v1_page(uuid, timestamptz, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_lead_page_details_v1(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_properties_v1_page(uuid, timestamptz, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_property_image_ids_v1(uuid, uuid[]) TO authenticated;
