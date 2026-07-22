-- Voya OS: controlled property creation with audit and transactional outbox.

ALTER TABLE public.properties ADD COLUMN idempotency_key text;
ALTER TABLE public.properties
  ADD CONSTRAINT properties_idempotency_key_unique UNIQUE (organization_id, idempotency_key);

CREATE OR REPLACE FUNCTION public.create_property(
  p_organization_id uuid,
  p_code text,
  p_name text,
  p_timezone text,
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
  existing_property public.properties%ROWTYPE;
  created_property_id uuid;
BEGIN
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0
    OR p_code IS NULL OR char_length(btrim(p_code)) = 0
    OR p_name IS NULL OR char_length(btrim(p_name)) = 0
    OR p_timezone IS NULL OR char_length(btrim(p_timezone)) = 0 THEN
    RAISE EXCEPTION 'property input is incomplete' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'property creation is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT property_record.* INTO existing_property
  FROM public.properties AS property_record
  WHERE property_record.organization_id = p_organization_id
    AND property_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF existing_property.code = p_code AND existing_property.name = p_name
      AND existing_property.timezone = p_timezone AND existing_property.status = 'active' THEN
      RETURN existing_property.id;
    END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.properties (organization_id, code, name, timezone, status, idempotency_key)
  VALUES (p_organization_id, p_code, p_name, p_timezone, 'active', p_idempotency_key)
  RETURNING id INTO created_property_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', actor_membership_id, 'property.created', 'property',
    created_property_id, 'success', p_request_id,
    jsonb_build_object('code', p_code, 'name', p_name, 'timezone', p_timezone, 'status', 'active')
  );

  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'property.created', 1, 'property:' || created_property_id::text,
    jsonb_build_object('property_id', created_property_id)
  );

  RETURN created_property_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_property(uuid, text, text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_property(uuid, text, text, text, text, uuid) TO authenticated;
