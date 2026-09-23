-- Close validated Auth/AuthZ scope gaps without changing public RPC contracts.
-- Existing implementations are retained under private compatibility names;
-- stable wrappers own the browser grants and enforce the missing boundary.

-- ---------------------------------------------------------------------------
-- Legacy lead read: NULL membership must fail closed.
-- ---------------------------------------------------------------------------

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

  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent') THEN
    RAISE EXCEPTION 'lead read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT lead.id, lead.title, lead.source, lead.status,
         lead.requested_check_in, lead.requested_check_out,
         lead.assigned_membership_id, lead.created_at
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

-- ---------------------------------------------------------------------------
-- Team administration: every browser-facing read/write requires AAL2.
-- ---------------------------------------------------------------------------

ALTER FUNCTION public.invite_organization_member_v1(uuid, text, text, text, text, uuid)
  RENAME TO invite_organization_member_v1_without_workspace_aal2;
ALTER FUNCTION public.resend_organization_invitation_v1(uuid, uuid, text, text, uuid)
  RENAME TO resend_organization_invitation_v1_without_workspace_aal2;
ALTER FUNCTION public.list_organization_members(uuid)
  RENAME TO list_organization_members_without_workspace_aal2;
ALTER FUNCTION public.list_organization_invitations(uuid)
  RENAME TO list_organization_invitations_without_workspace_aal2;
ALTER FUNCTION public.change_organization_member_role(uuid, uuid, text, uuid)
  RENAME TO change_organization_member_role_without_workspace_aal2;
ALTER FUNCTION public.suspend_organization_member(uuid, uuid, text, uuid)
  RENAME TO suspend_organization_member_without_workspace_aal2;
ALTER FUNCTION public.reactivate_organization_member(uuid, uuid, uuid)
  RENAME TO reactivate_organization_member_without_workspace_aal2;
ALTER FUNCTION public.remove_organization_member(uuid, uuid, text, uuid)
  RENAME TO remove_organization_member_without_workspace_aal2;
ALTER FUNCTION public.revoke_organization_invitation(uuid, uuid, uuid)
  RENAME TO revoke_organization_invitation_without_workspace_aal2;
ALTER FUNCTION public.resend_organization_invitation(uuid, uuid, uuid)
  RENAME TO resend_organization_invitation_without_workspace_aal2;

REVOKE ALL ON FUNCTION public.invite_organization_member_v1_without_workspace_aal2(uuid, text, text, text, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resend_organization_invitation_v1_without_workspace_aal2(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_organization_members_without_workspace_aal2(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_organization_invitations_without_workspace_aal2(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.change_organization_member_role_without_workspace_aal2(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.suspend_organization_member_without_workspace_aal2(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reactivate_organization_member_without_workspace_aal2(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.remove_organization_member_without_workspace_aal2(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.revoke_organization_invitation_without_workspace_aal2(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resend_organization_invitation_without_workspace_aal2(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.invite_organization_member_v1(
  p_organization_id uuid, p_email text, p_role text, p_token_digest text,
  p_sealed_token text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.invite_organization_member_v1_without_workspace_aal2(
    p_organization_id, p_email, p_role, p_token_digest, p_sealed_token, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.resend_organization_invitation_v1(
  p_organization_id uuid, p_invitation_id uuid, p_token_digest text,
  p_sealed_token text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.resend_organization_invitation_v1_without_workspace_aal2(
    p_organization_id, p_invitation_id, p_token_digest, p_sealed_token, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_organization_members(p_organization_id uuid)
RETURNS TABLE (id uuid, user_id uuid, display_name text, role text, status text, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_organization_members_without_workspace_aal2(p_organization_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.list_organization_invitations(p_organization_id uuid)
RETURNS TABLE (
  id uuid, normalized_email text, role text, status text, expires_at timestamptz,
  created_at timestamptz, accepted_at timestamptz, delivery_status text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_organization_invitations_without_workspace_aal2(p_organization_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.change_organization_member_role(
  p_organization_id uuid, p_membership_id uuid, p_role text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.change_organization_member_role_without_workspace_aal2(p_organization_id, p_membership_id, p_role, p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.suspend_organization_member(
  p_organization_id uuid, p_membership_id uuid, p_reason text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.suspend_organization_member_without_workspace_aal2(p_organization_id, p_membership_id, p_reason, p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.reactivate_organization_member(
  p_organization_id uuid, p_membership_id uuid, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.reactivate_organization_member_without_workspace_aal2(p_organization_id, p_membership_id, p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_organization_member(
  p_organization_id uuid, p_membership_id uuid, p_reason text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.remove_organization_member_without_workspace_aal2(p_organization_id, p_membership_id, p_reason, p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_organization_invitation(
  p_organization_id uuid, p_invitation_id uuid, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.revoke_organization_invitation_without_workspace_aal2(p_organization_id, p_invitation_id, p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.resend_organization_invitation(
  p_organization_id uuid, p_invitation_id uuid, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.resend_organization_invitation_without_workspace_aal2(p_organization_id, p_invitation_id, p_request_id);
END;
$$;

REVOKE ALL ON FUNCTION public.invite_organization_member_v1(uuid, text, text, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resend_organization_invitation_v1(uuid, uuid, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_organization_members(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_organization_invitations(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.change_organization_member_role(uuid, uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.suspend_organization_member(uuid, uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reactivate_organization_member(uuid, uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_organization_member(uuid, uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_organization_invitation(uuid, uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resend_organization_invitation(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invite_organization_member_v1(uuid, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resend_organization_invitation_v1(uuid, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_organization_members(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_organization_invitations(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.change_organization_member_role(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.suspend_organization_member(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reactivate_organization_member(uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_organization_member(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_organization_invitation(uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resend_organization_invitation(uuid, uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Operations task mutation: assignment is part of authorization.
-- ---------------------------------------------------------------------------

ALTER FUNCTION public.update_operations_task_status(uuid, uuid, text, uuid)
  RENAME TO update_operations_task_status_without_assignment_scope;
REVOKE ALL ON FUNCTION public.update_operations_task_status_without_assignment_scope(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.update_operations_task_status(
  p_organization_id uuid, p_task_id uuid, p_status text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_role text;
  v_actor uuid;
  v_assignee uuid;
BEGIN
  SELECT membership.role, membership.id
    INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'task update is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT task.assigned_membership_id
    INTO v_assignee
  FROM public.operations_tasks AS task
  WHERE task.organization_id = p_organization_id
    AND task.id = p_task_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'task is invalid' USING ERRCODE = '23503';
  END IF;
  IF v_role = 'operations'
    AND v_assignee IS NOT NULL
    AND v_assignee <> v_actor THEN
    RAISE EXCEPTION 'task is assigned to another operator' USING ERRCODE = '42501';
  END IF;

  RETURN public.update_operations_task_status_without_assignment_scope(
    p_organization_id, p_task_id, p_status, p_request_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.update_operations_task_status(uuid, uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_operations_task_status(uuid, uuid, text, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- CRM child records: sales agents inherit the lead assignment boundary.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.crm_sales_lead_scope_allows_v1(
  p_organization_id uuid, p_lead_id uuid, p_actor_membership_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.leads AS lead_record
    WHERE lead_record.organization_id = p_organization_id
      AND lead_record.id = p_lead_id
      AND (
        lead_record.assigned_membership_id IS NULL
        OR lead_record.assigned_membership_id = p_actor_membership_id
      )
  );
$$;
REVOKE ALL ON FUNCTION public.crm_sales_lead_scope_allows_v1(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;

ALTER FUNCTION public.create_lead_activity_v1(uuid, uuid, text, text, text, uuid)
  RENAME TO create_lead_activity_v1_without_lead_scope;
ALTER FUNCTION public.list_lead_activities_v1(uuid, uuid)
  RENAME TO list_lead_activities_v1_without_lead_scope;
ALTER FUNCTION public.create_lead_follow_up_v1(uuid, uuid, timestamptz, text, uuid, text, uuid)
  RENAME TO create_lead_follow_up_v1_without_lead_scope;
ALTER FUNCTION public.list_lead_follow_ups_v1(uuid, uuid)
  RENAME TO list_lead_follow_ups_v1_without_lead_scope;
ALTER FUNCTION public.complete_lead_follow_up_v1(uuid, uuid, text, text, uuid)
  RENAME TO complete_lead_follow_up_v1_without_lead_scope;

REVOKE ALL ON FUNCTION public.create_lead_activity_v1_without_lead_scope(uuid, uuid, text, text, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_lead_activities_v1_without_lead_scope(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_lead_follow_up_v1_without_lead_scope(uuid, uuid, timestamptz, text, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_lead_follow_ups_v1_without_lead_scope(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_lead_follow_up_v1_without_lead_scope(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.crm_sales_lead_write_allowed_v1(
  p_organization_id uuid, p_lead_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RETURN false;
  END IF;
  RETURN v_role <> 'sales_agent'
    OR public.crm_sales_lead_scope_allows_v1(p_organization_id, p_lead_id, v_actor);
END;
$$;
REVOKE ALL ON FUNCTION public.crm_sales_lead_write_allowed_v1(uuid, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.crm_sales_lead_read_allowed_v1(
  p_organization_id uuid, p_lead_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'viewer') THEN
    RETURN false;
  END IF;
  RETURN v_role <> 'sales_agent'
    OR public.crm_sales_lead_scope_allows_v1(p_organization_id, p_lead_id, v_actor);
END;
$$;
REVOKE ALL ON FUNCTION public.crm_sales_lead_read_allowed_v1(uuid, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_lead_activity_v1(
  p_organization_id uuid, p_lead_id uuid, p_activity_type text, p_content text,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT public.crm_sales_lead_write_allowed_v1(p_organization_id, p_lead_id) THEN
    RAISE EXCEPTION 'lead activity is not permitted' USING ERRCODE = '42501';
  END IF;
  v_id := public.create_lead_activity_v1_without_lead_scope(p_organization_id, p_lead_id, p_activity_type, p_content, p_idempotency_key, p_request_id);
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_lead_activities_v1(p_organization_id uuid, p_lead_id uuid)
RETURNS TABLE (id uuid, lead_id uuid, actor_membership_id uuid, activity_type text, content text, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF NOT public.crm_sales_lead_read_allowed_v1(p_organization_id, p_lead_id) THEN
    RAISE EXCEPTION 'lead activity read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT * FROM public.list_lead_activities_v1_without_lead_scope(p_organization_id, p_lead_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_lead_follow_up_v1(
  p_organization_id uuid, p_lead_id uuid, p_due_at timestamptz, p_note text,
  p_assigned_membership_id uuid, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF NOT public.crm_sales_lead_write_allowed_v1(p_organization_id, p_lead_id) THEN
    RAISE EXCEPTION 'lead follow-up is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN public.create_lead_follow_up_v1_without_lead_scope(
    p_organization_id, p_lead_id, p_due_at, p_note, p_assigned_membership_id, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_lead_follow_ups_v1(p_organization_id uuid, p_lead_id uuid)
RETURNS TABLE (
  id uuid, lead_id uuid, assigned_membership_id uuid, due_at timestamptz, note text,
  status text, completed_at timestamptz, completed_by_membership_id uuid, created_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF NOT public.crm_sales_lead_read_allowed_v1(p_organization_id, p_lead_id) THEN
    RAISE EXCEPTION 'lead follow-up read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT * FROM public.list_lead_follow_ups_v1_without_lead_scope(p_organization_id, p_lead_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_lead_follow_up_v1(
  p_organization_id uuid, p_follow_up_id uuid, p_note text,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_lead_id uuid;
BEGIN
  SELECT follow_up.lead_id INTO v_lead_id
  FROM public.crm_follow_ups AS follow_up
  WHERE follow_up.organization_id = p_organization_id
    AND follow_up.id = p_follow_up_id;
  IF NOT FOUND OR NOT public.crm_sales_lead_write_allowed_v1(p_organization_id, v_lead_id) THEN
    RAISE EXCEPTION 'follow-up completion is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN public.complete_lead_follow_up_v1_without_lead_scope(
    p_organization_id, p_follow_up_id, p_note, p_idempotency_key, p_request_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_lead_activity_v1(uuid, uuid, text, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_lead_activities_v1(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_lead_follow_up_v1(uuid, uuid, timestamptz, text, uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_lead_follow_ups_v1(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.complete_lead_follow_up_v1(uuid, uuid, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_lead_activity_v1(uuid, uuid, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_lead_activities_v1(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_lead_follow_up_v1(uuid, uuid, timestamptz, text, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_lead_follow_ups_v1(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_lead_follow_up_v1(uuid, uuid, text, text, uuid) TO authenticated;
