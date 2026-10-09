-- R10: expose expired confirmation approvals for pending bookings so staff can
-- request a fresh maker-checker review through the existing command.
CREATE OR REPLACE FUNCTION public.list_booking_approval_recovery_v1(
  p_organization_id uuid
)
RETURNS TABLE (booking_id uuid, approval_request_id uuid, expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_role text;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  SELECT membership.role INTO v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'booking approval recovery read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH latest AS (
    SELECT DISTINCT ON (request.resource_id)
      request.resource_id,
      request.id,
      request.expires_at
    FROM public.approval_requests AS request
    JOIN public.bookings AS booking
      ON booking.organization_id = request.organization_id
     AND booking.id = request.resource_id
    WHERE request.organization_id = p_organization_id
      AND request.resource_type = 'booking'
      AND request.proposed_action = 'booking.confirm'
      AND request.status IN ('pending', 'approved', 'expired')
      AND booking.status = 'pending_approval'
    ORDER BY request.resource_id, request.created_at DESC, request.id DESC
  )
  SELECT latest.resource_id, latest.id, latest.expires_at
  FROM latest
  WHERE latest.expires_at IS NOT NULL
    AND latest.expires_at <= timezone('utc', now())
  ORDER BY latest.expires_at, latest.resource_id;
END;
$$;

REVOKE ALL ON FUNCTION public.list_booking_approval_recovery_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_booking_approval_recovery_v1(uuid) TO authenticated;

-- R15: return a pending-only dashboard preview and a count calculated before
-- the display limit. Preserve requester-only visibility for non-admin roles.
CREATE OR REPLACE FUNCTION public.list_dashboard_approval_work_v1(
  p_organization_id uuid,
  p_pending_limit integer DEFAULT 4
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_role text;
  v_result jsonb;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_pending_limit IS NULL OR p_pending_limit < 1 OR p_pending_limit > 20 THEN
    RAISE EXCEPTION 'dashboard approval limit is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_actor IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant') THEN
    RAISE EXCEPTION 'dashboard approval read is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'pending_count', (
      SELECT count(*)
      FROM public.approval_requests AS request
      WHERE request.organization_id = p_organization_id
        AND request.status = 'pending'
        AND (v_role IN ('owner', 'manager') OR request.requester_membership_id = v_actor)
    ),
    'approvals', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', pending.id,
          'resource_type', pending.resource_type,
          'resource_id', pending.resource_id,
          'proposed_action', pending.proposed_action,
          'status', pending.status,
          'expires_at', pending.expires_at,
          'created_at', pending.created_at
        ) ORDER BY pending.created_at DESC, pending.id DESC
      )
      FROM (
        SELECT request.id, request.resource_type, request.resource_id,
               request.proposed_action, request.status, request.expires_at, request.created_at
        FROM public.approval_requests AS request
        WHERE request.organization_id = p_organization_id
          AND request.status = 'pending'
          AND (v_role IN ('owner', 'manager') OR request.requester_membership_id = v_actor)
        ORDER BY request.created_at DESC, request.id DESC
        LIMIT p_pending_limit
      ) AS pending
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.list_dashboard_approval_work_v1(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_dashboard_approval_work_v1(uuid, integer) TO authenticated;
