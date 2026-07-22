-- Voya OS: narrow, tenant-authorized property read contract.

CREATE OR REPLACE FUNCTION public.list_properties(
  p_organization_id uuid
)
RETURNS TABLE (
  id uuid,
  code text,
  name text,
  timezone text,
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
  ) THEN
    RAISE EXCEPTION 'property read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT property_record.id,
         property_record.code,
         property_record.name,
         property_record.timezone,
         property_record.status,
         property_record.created_at
  FROM public.properties AS property_record
  WHERE property_record.organization_id = p_organization_id
  ORDER BY property_record.created_at DESC, property_record.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_properties(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_properties(uuid) TO authenticated;
