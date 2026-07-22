-- Voya OS: make property-owner creation publish a durable internal event.

CREATE OR REPLACE FUNCTION public.create_property_owner(
  p_organization_id uuid,
  p_display_name text,
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
  existing_owner public.property_owners%ROWTYPE;
  created_owner_id uuid;
BEGIN
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency key is required' USING ERRCODE = '22023';
  END IF;

  IF p_display_name IS NULL OR char_length(btrim(p_display_name)) = 0 THEN
    RAISE EXCEPTION 'property owner display name is required' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id
  INTO actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');

  IF actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'property owner creation is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT owner_record.*
  INTO existing_owner
  FROM public.property_owners AS owner_record
  WHERE owner_record.organization_id = p_organization_id
    AND owner_record.idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF existing_owner.display_name = p_display_name
      AND existing_owner.status = 'active' THEN
      RETURN existing_owner.id;
    END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property owner' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.property_owners (
    organization_id, display_name, status, idempotency_key
  ) VALUES (
    p_organization_id, p_display_name, 'active', p_idempotency_key
  )
  RETURNING id INTO created_owner_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', actor_membership_id, 'property_owner.created',
    'property_owner', created_owner_id, 'success', p_request_id,
    jsonb_build_object('display_name', p_display_name, 'status', 'active')
  );

  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id,
    'property_owner.created',
    1,
    'property-owner:' || created_owner_id::text,
    jsonb_build_object('property_owner_id', created_owner_id)
  );

  RETURN created_owner_id;
END;
$$;
