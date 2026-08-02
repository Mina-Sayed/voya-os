-- Voya OS: tenant-scoped booking work queue read model.

CREATE OR REPLACE FUNCTION public.list_booking_drafts(p_organization_id uuid)
RETURNS TABLE (
  id uuid,
  property_id uuid,
  property_code text,
  property_name text,
  client_id uuid,
  client_name text,
  status text,
  check_in date,
  check_out date,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT membership.role INTO v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';

  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant') THEN
    RAISE EXCEPTION 'booking draft read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT booking.id,
         booking.property_id,
         property_record.code,
         property_record.name,
         booking.client_id,
         client_record.display_name,
         booking.status,
         booking.check_in,
         booking.check_out,
         booking.created_at
  FROM public.bookings AS booking
  JOIN public.properties AS property_record
    ON property_record.organization_id = booking.organization_id
   AND property_record.id = booking.property_id
  LEFT JOIN public.clients AS client_record
    ON client_record.organization_id = booking.organization_id
   AND client_record.id = booking.client_id
  WHERE booking.organization_id = p_organization_id
    AND booking.status = 'draft'
  ORDER BY booking.created_at DESC, booking.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_booking_drafts(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_booking_drafts(uuid) TO authenticated;
