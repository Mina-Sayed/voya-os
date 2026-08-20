CREATE OR REPLACE FUNCTION public.list_leads(p_organization_id uuid)
RETURNS TABLE(
  id uuid,
  title text,
  source text,
  status text,
  requested_check_in date,
  requested_check_out date,
  assigned_membership_id uuid,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_role text;
  v_member uuid;
BEGIN
  SELECT membership.role, membership.id
  INTO v_role, v_member
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';

  IF v_role NOT IN ('owner', 'manager', 'sales_agent') THEN
    RAISE EXCEPTION 'lead read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    lead.id,
    lead.title,
    lead.source,
    lead.status,
    lead.requested_check_in,
    lead.requested_check_out,
    lead.assigned_membership_id,
    lead.created_at
  FROM public.leads AS lead
  WHERE lead.organization_id = p_organization_id
    AND (
      v_role IN ('owner', 'manager')
      OR lead.assigned_membership_id IS NULL
      OR lead.assigned_membership_id = v_member
    )
  ORDER BY lead.created_at DESC, lead.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_leads(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.list_leads(uuid) TO authenticated;

