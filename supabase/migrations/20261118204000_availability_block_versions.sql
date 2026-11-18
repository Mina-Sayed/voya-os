-- Compare the version displayed on the form while holding the occupancy source lock.
ALTER TABLE public.availability_blocks
  ADD COLUMN version integer NOT NULL DEFAULT 1 CHECK (version > 0);

CREATE FUNCTION public.list_availability_blocks_v2(p_organization_id uuid)
RETURNS TABLE (
  id uuid, property_id uuid, start_date date, end_date date, block_type text,
  reason text, created_at timestamptz, version integer
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT visible.*, block_record.version
  FROM public.list_availability_blocks(p_organization_id) AS visible
  JOIN public.availability_blocks AS block_record
    ON block_record.organization_id = p_organization_id AND block_record.id = visible.id
  ORDER BY visible.start_date, visible.created_at DESC, visible.id DESC;
$$;
CREATE OR REPLACE FUNCTION public.update_availability_block_v2(
  p_organization_id uuid,
  p_block_id uuid,
  p_start_date date,
  p_end_date date,
  p_block_type text,
  p_reason text,
  p_expected_version integer,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  actor_membership_id uuid;
  existing_block public.availability_blocks%ROWTYPE;
  v_reason text := NULLIF(btrim(p_reason), '');
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_organization_id IS NULL OR p_block_id IS NULL
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_start_date IS NULL OR p_end_date IS NULL OR p_start_date >= p_end_date
    OR p_block_type IS NULL OR p_block_type NOT IN ('maintenance', 'owner_use', 'administrative')
    OR (v_reason IS NOT NULL AND char_length(v_reason) > 500) THEN
    RAISE EXCEPTION 'availability block input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'availability block update is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT block_record.* INTO existing_block
  FROM public.availability_blocks AS block_record
  WHERE block_record.organization_id = p_organization_id
    AND block_record.id = p_block_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'availability block was not found' USING ERRCODE = 'P0002';
  END IF;

  IF existing_block.version <> p_expected_version THEN
    RAISE EXCEPTION 'availability block changed; reload before editing' USING ERRCODE = 'P0001';
  END IF;

  IF existing_block.start_date = p_start_date AND existing_block.end_date = p_end_date
    AND existing_block.block_type = p_block_type AND existing_block.reason IS NOT DISTINCT FROM v_reason THEN
    RETURN existing_block.id;
  END IF;

  UPDATE public.availability_blocks
  SET start_date = p_start_date, end_date = p_end_date, block_type = p_block_type, reason = v_reason, version = version + 1
  WHERE organization_id = p_organization_id AND id = p_block_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', actor_membership_id, 'availability_block.updated', 'availability_block',
    p_block_id, 'success', p_request_id,
    jsonb_build_object('start_date', existing_block.start_date, 'end_date', existing_block.end_date, 'block_type', existing_block.block_type),
    jsonb_build_object('start_date', p_start_date, 'end_date', p_end_date, 'block_type', p_block_type)
  );

  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'availability_block.updated', 1,
    'availability-block-update:' || p_block_id::text || ':' || gen_random_uuid()::text,
    jsonb_build_object('availability_block_id', p_block_id)
  );
  RETURN p_block_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_availability_block_v2(
  p_organization_id uuid,
  p_block_id uuid,
  p_expected_version integer,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  actor_membership_id uuid;
  existing_block public.availability_blocks%ROWTYPE;
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  IF p_organization_id IS NULL OR p_block_id IS NULL
    OR p_expected_version IS NULL OR p_expected_version < 1 THEN
    RAISE EXCEPTION 'availability block input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'availability block deletion is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT block_record.* INTO existing_block
  FROM public.availability_blocks AS block_record
  WHERE block_record.organization_id = p_organization_id AND block_record.id = p_block_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF existing_block.version <> p_expected_version THEN
    RAISE EXCEPTION 'availability block changed; reload before deleting' USING ERRCODE = 'P0001';
  END IF;
  DELETE FROM public.availability_blocks
  WHERE organization_id = p_organization_id AND id = p_block_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, before_delta
  ) VALUES (
    p_organization_id, 'user', actor_membership_id, 'availability_block.deleted', 'availability_block',
    p_block_id, 'success', p_request_id,
    jsonb_build_object('property_id', existing_block.property_id, 'start_date', existing_block.start_date,
      'end_date', existing_block.end_date, 'block_type', existing_block.block_type)
  );

  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'availability_block.deleted', 1,
    'availability-block-delete:' || p_block_id::text,
    jsonb_build_object('availability_block_id', p_block_id)
  );
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.list_availability_blocks_v2(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.list_availability_blocks_v2(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.update_availability_block_v2(uuid, uuid, date, date, text, text, integer, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.update_availability_block_v2(uuid, uuid, date, date, text, text, integer, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.delete_availability_block_v2(uuid, uuid, integer, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.delete_availability_block_v2(uuid, uuid, integer, uuid) TO authenticated;

-- The unversioned entry points cannot safely accept writes from an old tab.
REVOKE ALL ON FUNCTION public.update_availability_block_v1(uuid, uuid, date, date, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_availability_block_v1(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;
