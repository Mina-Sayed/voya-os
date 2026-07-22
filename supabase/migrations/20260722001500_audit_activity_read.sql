-- Voya OS: redacted, role-scoped activity feed over immutable audit facts.

CREATE OR REPLACE FUNCTION public.list_audit_activity(
  p_organization_id uuid,
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  id uuid,
  action text,
  resource_type text,
  resource_id uuid,
  outcome text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_actor_role text;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'audit activity limit is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id, membership.role INTO v_actor_membership_id, v_actor_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_actor_membership_id IS NULL OR v_actor_role = 'viewer' THEN
    RAISE EXCEPTION 'audit activity read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT audit.id, audit.action, audit.resource_type, audit.resource_id, audit.outcome, audit.created_at
  FROM public.audit_events AS audit
  WHERE audit.organization_id = p_organization_id
    AND (
      v_actor_role IN ('owner', 'manager')
      OR (v_actor_role IN ('sales_agent', 'operations') AND audit.actor_membership_id = v_actor_membership_id)
      OR (v_actor_role = 'accountant' AND audit.action ~ '^(payment|expense|commission|settlement)[.]')
    )
  ORDER BY audit.created_at DESC, audit.id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.list_audit_activity(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_audit_activity(uuid, integer) TO authenticated;
