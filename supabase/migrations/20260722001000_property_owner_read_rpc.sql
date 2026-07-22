-- Voya OS: narrow, tenant-authorized property-owner read contract.

CREATE OR REPLACE FUNCTION public.list_property_owners(
  p_organization_id uuid
)
RETURNS TABLE (
  id uuid,
  display_name text,
  status text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id
      AND membership.user_id = auth.uid()
      AND membership.status = 'active'
      AND membership.role IN ('owner', 'manager', 'operations')
  ) THEN
    RAISE EXCEPTION 'property owner read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT owner_record.id,
         owner_record.display_name,
         owner_record.status,
         owner_record.created_at
  FROM public.property_owners AS owner_record
  WHERE owner_record.organization_id = p_organization_id
  ORDER BY owner_record.created_at DESC, owner_record.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_property_owners(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_property_owners(uuid) TO authenticated;
