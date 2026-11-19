-- Keep pending requests visible independently of the volume of decision history.
CREATE INDEX approval_requests_workspace_page_idx
  ON public.approval_requests (organization_id, created_at DESC, id DESC);
CREATE INDEX approval_requests_pending_page_idx
  ON public.approval_requests (organization_id, created_at DESC, id DESC)
  WHERE status = 'pending';

CREATE FUNCTION public.get_booking_approval_readiness_v1(p_organization_id uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid()
      AND membership.status = 'active' AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations')
  ) THEN
    RAISE EXCEPTION 'booking approval readiness read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN (SELECT count(*) >= 2 FROM public.organization_memberships AS reviewer
    WHERE reviewer.organization_id = p_organization_id AND reviewer.status = 'active'
      AND reviewer.role IN ('owner', 'manager'));
END;
$$;
CREATE OR REPLACE FUNCTION public.list_approval_requests_v3(
  p_organization_id uuid,
  p_limit integer DEFAULT 50,
  p_pending_only boolean DEFAULT true,
  p_before_created_at timestamptz DEFAULT NULL,
  p_before_id uuid DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  resource_type text,
  resource_id uuid,
  proposed_action text,
  status text,
  expires_at timestamptz,
  created_at timestamptz,
  proposal_summary jsonb,
  requester_display_name text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_membership_id uuid;
  v_role text;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_pending_only IS NULL OR (p_before_created_at IS NULL) <> (p_before_id IS NULL)
    OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'approval request limit is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id, membership.role INTO v_membership_id, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_membership_id IS NULL OR v_role = 'viewer' THEN
    RAISE EXCEPTION 'approval request read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT request.id,
    request.resource_type,
    request.resource_id,
    request.proposed_action,
    request.status,
    request.expires_at,
    request.created_at,
    CASE request.proposed_action
      WHEN 'booking.confirm' THEN jsonb_build_object(
        'checkIn', request.proposal_snapshot->>'check_in',
        'checkOut', request.proposal_snapshot->>'check_out',
        'amountMinor', request.proposal_snapshot->>'agreed_total_amount_minor',
        'currency', request.proposal_snapshot->>'currency',
        'propertyId', request.proposal_snapshot->>'property_id',
        'clientId', request.proposal_snapshot->>'client_id'
      )
      WHEN 'booking.amend' THEN jsonb_build_object(
        'checkIn', request.proposal_snapshot->>'check_in',
        'checkOut', request.proposal_snapshot->>'check_out',
        'amountMinor', request.proposal_snapshot->>'agreed_total_amount_minor',
        'currency', request.proposal_snapshot->>'currency',
        'reason', request.proposal_snapshot->>'reason',
        'propertyId', request.proposal_snapshot->>'property_id',
        'clientId', request.proposal_snapshot->>'client_id',
        'propertyLabel', (
          SELECT property_record.code || ' — ' || property_record.name
          FROM public.properties AS property_record
          WHERE property_record.organization_id = request.organization_id
            AND property_record.id = (request.proposal_snapshot->>'property_id')::uuid
        ),
        'clientLabel', (
          SELECT client_record.display_name
          FROM public.clients AS client_record
          WHERE client_record.organization_id = request.organization_id
            AND client_record.id = (request.proposal_snapshot->>'client_id')::uuid
        )
      )
      WHEN 'booking.cancel' THEN jsonb_build_object(
        'checkIn', booking_record.check_in::text,
        'checkOut', booking_record.check_out::text,
        'amountMinor', booking_record.agreed_total_amount_minor::text,
        'currency', booking_record.currency,
        'reason', request.proposal_snapshot->>'reason',
        'propertyId', booking_record.property_id::text,
        'clientId', booking_record.client_id::text,
        'propertyLabel', property_record.code || ' — ' || property_record.name,
        'clientLabel', COALESCE(client_record.display_name, 'عميل غير مرتبط')
      )
      ELSE '{}'::jsonb
    END,
    profile.display_name
  FROM public.approval_requests AS request
  JOIN public.organization_memberships AS requester
    ON requester.organization_id = request.organization_id
   AND requester.id = request.requester_membership_id
  LEFT JOIN public.profiles AS profile
    ON profile.id = requester.user_id
  LEFT JOIN public.bookings AS booking_record
    ON booking_record.organization_id = request.organization_id
   AND booking_record.id = request.resource_id
   AND request.resource_type = 'booking'
  LEFT JOIN public.properties AS property_record
    ON property_record.organization_id = booking_record.organization_id
   AND property_record.id = booking_record.property_id
  LEFT JOIN public.clients AS client_record
    ON client_record.organization_id = booking_record.organization_id
   AND client_record.id = booking_record.client_id
  WHERE request.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager') OR request.requester_membership_id = v_membership_id)
    AND (NOT p_pending_only OR (request.status = 'pending' AND (request.expires_at IS NULL OR request.expires_at > now())))
    AND (p_before_id IS NULL OR (request.created_at, request.id) < (p_before_created_at, p_before_id))
  ORDER BY request.created_at DESC, request.id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_booking_approval_readiness_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_booking_approval_readiness_v1(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.list_approval_requests_v3(uuid, integer, boolean, timestamptz, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.list_approval_requests_v3(uuid, integer, boolean, timestamptz, uuid) TO authenticated;
