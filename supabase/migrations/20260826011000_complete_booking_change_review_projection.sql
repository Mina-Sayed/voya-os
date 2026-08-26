-- Complete the safe reviewer projection for both amendment and cancellation.
-- Cancellation snapshots intentionally store only booking_version + reason; the
-- current booking row is safe to project because decide_booking_approval now
-- rejects the request if that version no longer matches at decision time.

CREATE OR REPLACE FUNCTION public.list_approval_requests_v2(
  p_organization_id uuid,
  p_limit integer DEFAULT 50
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
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
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
        'clientLabel', client_record.display_name
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
  ORDER BY request.created_at DESC, request.id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.list_approval_requests_v2(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_approval_requests_v2(uuid, integer) TO authenticated;
