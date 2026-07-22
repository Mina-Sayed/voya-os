-- Voya OS: controlled creation of a non-confirmed booking proposal.
-- Confirmation, cancellation, financial effects, and approval execution remain
-- unavailable through this function.

CREATE OR REPLACE FUNCTION public.create_booking_draft(
  p_organization_id uuid,
  p_property_id uuid,
  p_client_id uuid,
  p_check_in date,
  p_check_out date,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  actor_membership_id uuid;
  existing_booking public.bookings%ROWTYPE;
  created_booking_id uuid;
BEGIN
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency key is required' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id
  INTO actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');

  IF actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'booking draft creation is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT booking.*
  INTO existing_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = p_organization_id
    AND booking.idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF existing_booking.property_id = p_property_id
      AND existing_booking.client_id = p_client_id
      AND existing_booking.status = 'draft'
      AND existing_booking.check_in = p_check_in
      AND existing_booking.check_out = p_check_out THEN
      RETURN existing_booking.id;
    END IF;

    RAISE EXCEPTION 'idempotency key belongs to a different booking draft' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.bookings (
    organization_id,
    property_id,
    client_id,
    status,
    check_in,
    check_out,
    idempotency_key
  ) VALUES (
    p_organization_id,
    p_property_id,
    p_client_id,
    'draft',
    p_check_in,
    p_check_out,
    p_idempotency_key
  )
  RETURNING id INTO created_booking_id;

  INSERT INTO public.audit_events (
    organization_id,
    actor_type,
    actor_membership_id,
    action,
    resource_type,
    resource_id,
    outcome,
    request_id,
    after_delta
  ) VALUES (
    p_organization_id,
    'user',
    actor_membership_id,
    'booking.draft_created',
    'booking',
    created_booking_id,
    'success',
    p_request_id,
    jsonb_build_object(
      'status', 'draft',
      'property_id', p_property_id,
      'client_id', p_client_id,
      'check_in', p_check_in,
      'check_out', p_check_out
    )
  );

  RETURN created_booking_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_booking_draft(uuid, uuid, uuid, date, date, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_booking_draft(uuid, uuid, uuid, date, date, text, uuid) TO authenticated;
