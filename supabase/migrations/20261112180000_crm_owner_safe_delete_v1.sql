-- CRM owner-only permanent delete for unlinked leads/clients.
-- No cascade and no bypass of immutable CRM, booking, audit or WhatsApp history.
-- Existing archive actions remain the documented fallback for linked records.
--
-- One row per command, transactionally:
--   AAL2 + tenant owner -> compare name/version -> delete only if no FK references
--   -> append privacy-safe audit evidence. All unsafe paths fail closed.
-- Database FK RESTRICT checks remain the definitive dependency gate, including
-- for references introduced by future migrations.

CREATE OR REPLACE FUNCTION public.delete_crm_lead_v1(
  p_organization_id uuid,
  p_lead_id uuid,
  p_expected_version integer,
  p_confirm_name text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_lead public.leads%ROWTYPE;
BEGIN
  PERFORM public.require_workspace_aal2_v1();

  IF p_organization_id IS NULL OR p_lead_id IS NULL
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_confirm_name IS NULL OR length(btrim(p_confirm_name)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'CRM delete confirmation is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT m.id INTO v_actor
  FROM public.organization_memberships AS m
  WHERE m.organization_id = p_organization_id
    AND m.user_id = auth.uid()
    AND m.status = 'active'
    AND m.role = 'owner';
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'CRM permanent delete is owner-only' USING ERRCODE = '42501';
  END IF;

  SELECT l.* INTO v_lead
  FROM public.leads AS l
  WHERE l.organization_id = p_organization_id AND l.id = p_lead_id
  FOR UPDATE;
  IF NOT FOUND OR v_lead.version <> p_expected_version THEN
    RAISE EXCEPTION 'CRM lead changed or was removed' USING ERRCODE = '40001';
  END IF;
  IF btrim(p_confirm_name) <> coalesce(nullif(btrim(v_lead.name), ''), btrim(v_lead.title)) THEN
    RAISE EXCEPTION 'CRM name confirmation does not match' USING ERRCODE = '22023';
  END IF;

  -- Force a friendly failure before attempting deletion of an immutable record.
  -- The unrestricted FK RESTRICT constraints still protect every other relation.
  IF EXISTS (
    SELECT 1 FROM public.crm_activities AS a
    WHERE a.organization_id = p_organization_id AND a.lead_id = p_lead_id
  ) THEN
    RAISE EXCEPTION 'CRM lead has immutable activity history; archive it instead'
      USING ERRCODE = '23503';
  END IF;

  DELETE FROM public.leads
  WHERE organization_id = p_organization_id AND id = p_lead_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CRM lead changed' USING ERRCODE = '40001';
  END IF;

  -- No customer names, emails, phone numbers or notes in the permanent audit.
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'lead.deleted',
    'lead', p_lead_id, 'success', p_request_id,
    jsonb_build_object('deleted', true, 'prior_version', p_expected_version)
  );
  RETURN true;
EXCEPTION WHEN foreign_key_violation THEN
  RAISE EXCEPTION 'CRM lead has linked records; archive it instead'
    USING ERRCODE = '23503';
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_crm_client_v1(
  p_organization_id uuid,
  p_client_id uuid,
  p_expected_version integer,
  p_confirm_name text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid;
  v_client public.clients%ROWTYPE;
BEGIN
  PERFORM public.require_workspace_aal2_v1();

  IF p_organization_id IS NULL OR p_client_id IS NULL
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_confirm_name IS NULL OR length(btrim(p_confirm_name)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'CRM delete confirmation is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT m.id INTO v_actor
  FROM public.organization_memberships AS m
  WHERE m.organization_id = p_organization_id
    AND m.user_id = auth.uid()
    AND m.status = 'active'
    AND m.role = 'owner';
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'CRM permanent delete is owner-only' USING ERRCODE = '42501';
  END IF;

  SELECT c.* INTO v_client
  FROM public.clients AS c
  WHERE c.organization_id = p_organization_id AND c.id = p_client_id
  FOR UPDATE;
  IF NOT FOUND OR v_client.version <> p_expected_version THEN
    RAISE EXCEPTION 'CRM client changed or was removed' USING ERRCODE = '40001';
  END IF;
  IF btrim(p_confirm_name) <> btrim(v_client.display_name) THEN
    RAISE EXCEPTION 'CRM name confirmation does not match' USING ERRCODE = '22023';
  END IF;

  -- Bookings, messages, lead conversions and consent records are all RESTRICT.
  -- We deliberately do not cascade or detach them to enable a deletion.
  DELETE FROM public.clients
  WHERE organization_id = p_organization_id AND id = p_client_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CRM client changed' USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action,
    resource_type, resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'client.deleted',
    'client', p_client_id, 'success', p_request_id,
    jsonb_build_object('deleted', true, 'prior_version', p_expected_version)
  );
  RETURN true;
EXCEPTION WHEN foreign_key_violation THEN
  RAISE EXCEPTION 'CRM client has linked records; archive it instead'
    USING ERRCODE = '23503';
END;
$$;

REVOKE ALL ON FUNCTION public.delete_crm_lead_v1(uuid,uuid,integer,text,uuid)
  FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.delete_crm_client_v1(uuid,uuid,integer,text,uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.delete_crm_lead_v1(uuid,uuid,integer,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_crm_client_v1(uuid,uuid,integer,text,uuid) TO authenticated;

COMMENT ON FUNCTION public.delete_crm_lead_v1(uuid,uuid,integer,text,uuid) IS
  'Owner-only AAL2 hard-delete of an unlinked lead with typed name and version confirmation; audit retained.';
COMMENT ON FUNCTION public.delete_crm_client_v1(uuid,uuid,integer,text,uuid) IS
  'Owner-only AAL2 hard-delete of an unlinked client with typed name and version confirmation; audit retained.';
