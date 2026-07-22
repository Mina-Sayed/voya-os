-- Voya OS: redacted, requester-scoped approval queue reads.

CREATE OR REPLACE FUNCTION public.list_approval_requests(
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
  created_at timestamptz
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
  SELECT request.id, request.resource_type, request.resource_id, request.proposed_action,
         request.status, request.expires_at, request.created_at
  FROM public.approval_requests AS request
  WHERE request.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager') OR request.requester_membership_id = v_membership_id)
  ORDER BY request.created_at DESC, request.id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.list_approval_requests(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_approval_requests(uuid, integer) TO authenticated;
