-- Voya OS: controlled manual availability blocks backed by the occupancy ledger.

ALTER TABLE public.availability_blocks ADD COLUMN idempotency_key text;
ALTER TABLE public.availability_blocks
  ADD CONSTRAINT availability_blocks_idempotency_key_unique UNIQUE (organization_id, idempotency_key);

CREATE OR REPLACE FUNCTION public.create_availability_block(
  p_organization_id uuid,
  p_property_id uuid,
  p_start_date date,
  p_end_date date,
  p_block_type text,
  p_reason text,
  p_idempotency_key text,
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
  created_block_id uuid;
BEGIN
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0
    OR p_property_id IS NULL OR p_start_date IS NULL OR p_end_date IS NULL
    OR p_start_date >= p_end_date
    OR p_block_type NOT IN ('maintenance', 'owner_use', 'administrative') THEN
    RAISE EXCEPTION 'availability block input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'availability block creation is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT block_record.* INTO existing_block
  FROM public.availability_blocks AS block_record
  WHERE block_record.organization_id = p_organization_id
    AND block_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF existing_block.property_id = p_property_id AND existing_block.start_date = p_start_date
      AND existing_block.end_date = p_end_date AND existing_block.block_type = p_block_type
      AND existing_block.reason IS NOT DISTINCT FROM p_reason THEN
      RETURN existing_block.id;
    END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different availability block' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.availability_blocks (
    organization_id, property_id, start_date, end_date, block_type, reason, idempotency_key
  ) VALUES (
    p_organization_id, p_property_id, p_start_date, p_end_date, p_block_type, p_reason, p_idempotency_key
  ) RETURNING id INTO created_block_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', actor_membership_id, 'availability_block.created', 'availability_block',
    created_block_id, 'success', p_request_id,
    jsonb_build_object('property_id', p_property_id, 'start_date', p_start_date, 'end_date', p_end_date, 'block_type', p_block_type)
  );

  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (p_organization_id, 'availability_block.created', 1, 'availability-block:' || created_block_id::text, jsonb_build_object('availability_block_id', created_block_id));
  RETURN created_block_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_availability_blocks(p_organization_id uuid)
RETURNS TABLE (id uuid, property_id uuid, start_date date, end_date date, block_type text, reason text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id AND membership.user_id = auth.uid() AND membership.status = 'active'
  ) THEN RAISE EXCEPTION 'availability block read is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY SELECT block_record.id, block_record.property_id, block_record.start_date, block_record.end_date, block_record.block_type, block_record.reason, block_record.created_at
  FROM public.availability_blocks AS block_record
  WHERE block_record.organization_id = p_organization_id
  ORDER BY block_record.start_date ASC, block_record.end_date ASC, block_record.id ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.create_availability_block(uuid, uuid, date, date, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_availability_blocks(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_availability_block(uuid, uuid, date, date, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_availability_blocks(uuid) TO authenticated;
