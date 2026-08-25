-- Voya OS: decision-sufficient booking read surfaces and bounded work queue.

DROP FUNCTION IF EXISTS public.list_commercial_booking_work_queue(uuid);
CREATE FUNCTION public.list_commercial_booking_work_queue(
  p_organization_id uuid,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid, property_id uuid, property_code text, property_name text,
  client_id uuid, client_name text, status text, check_in date, check_out date,
  agreed_total_amount_minor text, currency text, commercial_completion_status text,
  version integer, has_check_in boolean, has_check_out boolean,
  confirmation_approval_status text, amendment_approval_status text,
  cancellation_approval_status text, created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_role text;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 THEN
    RAISE EXCEPTION 'booking queue pagination is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.role INTO v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner','manager','sales_agent','operations','accountant','viewer') THEN
    RAISE EXCEPTION 'commercial booking read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT booking.id, booking.property_id, property_record.code, property_record.name,
    booking.client_id, client_record.display_name, booking.status, booking.check_in, booking.check_out,
    booking.agreed_total_amount_minor::text, booking.currency, booking.commercial_completion_status,
    booking.version,
    EXISTS (SELECT 1 FROM public.booking_stay_events e WHERE e.organization_id = booking.organization_id AND e.booking_id = booking.id AND e.event_type = 'check_in'),
    EXISTS (SELECT 1 FROM public.booking_stay_events e WHERE e.organization_id = booking.organization_id AND e.booking_id = booking.id AND e.event_type = 'check_out'),
    confirmation.effective_status, amendment.effective_status, cancellation.effective_status,
    booking.created_at
  FROM public.bookings AS booking
  JOIN public.properties AS property_record ON property_record.organization_id = booking.organization_id AND property_record.id = booking.property_id
  LEFT JOIN public.clients AS client_record ON client_record.organization_id = booking.organization_id AND client_record.id = booking.client_id
  LEFT JOIN LATERAL (
    SELECT CASE WHEN request.status = 'pending' AND request.expires_at IS NOT NULL AND request.expires_at <= clock_timestamp() THEN 'expired' ELSE request.status END AS effective_status
    FROM public.approval_requests request
    WHERE request.organization_id = booking.organization_id AND request.resource_type = 'booking' AND request.resource_id = booking.id AND request.proposed_action = 'booking.confirm'
    ORDER BY request.created_at DESC, request.id DESC LIMIT 1
  ) confirmation ON true
  LEFT JOIN LATERAL (
    SELECT CASE WHEN request.status = 'pending' AND request.expires_at IS NOT NULL AND request.expires_at <= clock_timestamp() THEN 'expired' ELSE request.status END AS effective_status
    FROM public.approval_requests request
    WHERE request.organization_id = booking.organization_id AND request.resource_type = 'booking' AND request.resource_id = booking.id AND request.proposed_action = 'booking.amend'
    ORDER BY request.created_at DESC, request.id DESC LIMIT 1
  ) amendment ON true
  LEFT JOIN LATERAL (
    SELECT CASE WHEN request.status = 'pending' AND request.expires_at IS NOT NULL AND request.expires_at <= clock_timestamp() THEN 'expired' ELSE request.status END AS effective_status
    FROM public.approval_requests request
    WHERE request.organization_id = booking.organization_id AND request.resource_type = 'booking' AND request.resource_id = booking.id AND request.proposed_action = 'booking.cancel'
    ORDER BY request.created_at DESC, request.id DESC LIMIT 1
  ) cancellation ON true
  WHERE booking.organization_id = p_organization_id
  ORDER BY (booking.status IN ('completed','checked_out','cancelled')), booking.check_in, booking.created_at DESC, booking.id DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$;
REVOKE ALL ON FUNCTION public.list_commercial_booking_work_queue(uuid,integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_commercial_booking_work_queue(uuid,integer,integer) TO authenticated;

DROP FUNCTION IF EXISTS public.list_approval_requests(uuid, integer);
CREATE FUNCTION public.list_approval_requests(p_organization_id uuid, p_limit integer DEFAULT 50)
RETURNS TABLE (
  id uuid, resource_type text, resource_id uuid, proposed_action text, status text,
  expires_at timestamptz, created_at timestamptz, requester_name text,
  current_property_code text, current_property_name text, current_client_name text,
  current_check_in date, current_check_out date, current_amount_minor text, current_currency text,
  proposed_property_code text, proposed_property_name text, proposed_client_name text,
  proposed_check_in date, proposed_check_out date, proposed_amount_minor text,
  proposed_currency text, reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_membership_id uuid; v_role text;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN RAISE EXCEPTION 'approval request limit is invalid' USING ERRCODE = '22023'; END IF;
  SELECT membership.id, membership.role INTO v_membership_id, v_role
  FROM public.organization_memberships membership
  WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active';
  IF v_membership_id IS NULL OR v_role = 'viewer' THEN RAISE EXCEPTION 'approval request read is not permitted' USING ERRCODE = '42501'; END IF;

  RETURN QUERY
  SELECT request.id, request.resource_type, request.resource_id, request.proposed_action,
    CASE WHEN request.status = 'pending' AND request.expires_at IS NOT NULL AND request.expires_at <= clock_timestamp() THEN 'expired' ELSE request.status END,
    request.expires_at, request.created_at, COALESCE(profile.display_name, 'عضو فريق'),
    current_property.code, current_property.name, current_client.display_name,
    booking.check_in, booking.check_out, booking.agreed_total_amount_minor::text, booking.currency,
    proposed_property.code, proposed_property.name, proposed_client.display_name,
    CASE WHEN request.proposal_snapshot ? 'check_in' AND (request.proposal_snapshot->>'check_in') ~ '^\\d{4}-\\d{2}-\\d{2}$' THEN (request.proposal_snapshot->>'check_in')::date ELSE NULL END,
    CASE WHEN request.proposal_snapshot ? 'check_out' AND (request.proposal_snapshot->>'check_out') ~ '^\\d{4}-\\d{2}-\\d{2}$' THEN (request.proposal_snapshot->>'check_out')::date ELSE NULL END,
    request.proposal_snapshot->>'agreed_total_amount_minor', request.proposal_snapshot->>'currency', request.proposal_snapshot->>'reason'
  FROM public.approval_requests request
  LEFT JOIN public.organization_memberships requester ON requester.organization_id = request.organization_id AND requester.id = request.requester_membership_id
  LEFT JOIN public.profiles profile ON profile.id = requester.user_id
  LEFT JOIN public.bookings booking ON request.resource_type = 'booking' AND booking.organization_id = request.organization_id AND booking.id = request.resource_id
  LEFT JOIN public.properties current_property ON current_property.organization_id = booking.organization_id AND current_property.id = booking.property_id
  LEFT JOIN public.clients current_client ON current_client.organization_id = booking.organization_id AND current_client.id = booking.client_id
  LEFT JOIN public.properties proposed_property ON proposed_property.organization_id = request.organization_id AND proposed_property.id = CASE WHEN (request.proposal_snapshot->>'property_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN (request.proposal_snapshot->>'property_id')::uuid ELSE NULL END
  LEFT JOIN public.clients proposed_client ON proposed_client.organization_id = request.organization_id AND proposed_client.id = CASE WHEN (request.proposal_snapshot->>'client_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN (request.proposal_snapshot->>'client_id')::uuid ELSE NULL END
  WHERE request.organization_id = p_organization_id
    AND (v_role IN ('owner','manager') OR request.requester_membership_id = v_membership_id)
  ORDER BY request.created_at DESC, request.id DESC LIMIT p_limit;
END;
$$;
REVOKE ALL ON FUNCTION public.list_approval_requests(uuid,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_approval_requests(uuid,integer) TO authenticated;

-- Confirmation must re-check the client at the state transition, not only at draft creation.
CREATE OR REPLACE FUNCTION public.guard_confirmed_booking_client_active()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF NEW.status = 'confirmed' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'confirmed') THEN
    IF NEW.client_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.clients client
      WHERE client.organization_id = NEW.organization_id AND client.id = NEW.client_id AND client.archived_at IS NULL
    ) THEN
      RAISE EXCEPTION 'confirmed booking client must be active' USING ERRCODE = '23503';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS bookings_guard_confirmed_client_active ON public.bookings;
CREATE TRIGGER bookings_guard_confirmed_client_active BEFORE INSERT OR UPDATE OF status ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.guard_confirmed_booking_client_active();
REVOKE ALL ON FUNCTION public.guard_confirmed_booking_client_active() FROM PUBLIC, anon, authenticated;
