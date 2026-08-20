-- Voya OS V1: role-scoped audit filters and redacted event details.
-- The original list_audit_activity(uuid, integer) remains for compatibility.

CREATE OR REPLACE FUNCTION public.list_audit_activity_filtered(
  p_organization_id uuid,
  p_limit integer DEFAULT 50,
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_actor_membership_id uuid DEFAULT NULL,
  p_action text DEFAULT NULL,
  p_resource_type text DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  action text,
  resource_type text,
  resource_id uuid,
  actor_type text,
  actor_membership_id uuid,
  actor_display_name text,
  outcome text,
  reason_code text,
  before_delta jsonb,
  after_delta jsonb,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_actor_role text;
  v_action text := NULLIF(btrim(p_action), '');
  v_resource_type text := NULLIF(btrim(p_resource_type), '');
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
    OR (p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to)
    OR char_length(coalesce(v_action, '')) > 160
    OR char_length(coalesce(v_resource_type, '')) > 120 THEN
    RAISE EXCEPTION 'audit activity filter is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id, membership.role INTO v_actor_membership_id, v_actor_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_actor_membership_id IS NULL OR v_actor_role = 'viewer' THEN
    RAISE EXCEPTION 'audit activity read is not permitted' USING ERRCODE = '42501';
  END IF;

  IF p_actor_membership_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id
      AND membership.id = p_actor_membership_id
  ) THEN
    RAISE EXCEPTION 'audit actor filter is invalid' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT audit.id,
    audit.action,
    audit.resource_type,
    audit.resource_id,
    audit.actor_type,
    audit.actor_membership_id,
    CASE WHEN audit.actor_type = 'system' THEN 'النظام' ELSE COALESCE(profile.display_name, 'عضو') END,
    audit.outcome,
    audit.reason_code,
    audit.before_delta,
    audit.after_delta,
    audit.created_at
  FROM public.audit_events AS audit
  LEFT JOIN public.organization_memberships AS actor_membership
    ON actor_membership.organization_id = audit.organization_id
   AND actor_membership.id = audit.actor_membership_id
  LEFT JOIN public.profiles AS profile
    ON profile.id = actor_membership.user_id
  WHERE audit.organization_id = p_organization_id
    AND (v_actor_role IN ('owner', 'manager')
      OR (v_actor_role IN ('sales_agent', 'operations') AND audit.actor_membership_id = v_actor_membership_id)
      OR (v_actor_role = 'accountant' AND audit.action ~ '^(payment|expense|commission|settlement)[.]'))
    AND (p_from IS NULL OR audit.created_at >= p_from)
    AND (p_to IS NULL OR audit.created_at <= p_to)
    AND (p_actor_membership_id IS NULL OR audit.actor_membership_id = p_actor_membership_id)
    AND (v_action IS NULL OR audit.action = v_action)
    AND (v_resource_type IS NULL OR audit.resource_type = v_resource_type)
  ORDER BY audit.created_at DESC, audit.id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.list_audit_activity_filtered(uuid, integer, timestamptz, timestamptz, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_audit_activity_filtered(uuid, integer, timestamptz, timestamptz, uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.list_audit_activity_filtered(uuid, integer, timestamptz, timestamptz, uuid, text, text) IS
  'Role-scoped audit filters with redacted actor and before/after details; never exposes raw audit table access.';
