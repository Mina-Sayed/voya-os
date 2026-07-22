-- Voya OS: command-owned client registry. Contact/lead PII remains out of scope.

ALTER TABLE public.clients ADD COLUMN idempotency_key text;
ALTER TABLE public.clients
  ADD CONSTRAINT clients_idempotency_key_unique UNIQUE (organization_id, idempotency_key);

REVOKE SELECT ON TABLE public.clients FROM authenticated;

CREATE OR REPLACE FUNCTION public.create_client(
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
  existing_client public.clients%ROWTYPE;
  created_client_id uuid;
BEGIN
  IF p_display_name IS NULL OR char_length(btrim(p_display_name)) = 0
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'client input is incomplete' USING ERRCODE = '22023';
  END IF;

  SELECT membership.id INTO actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'client creation is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT client_record.* INTO existing_client
  FROM public.clients AS client_record
  WHERE client_record.organization_id = p_organization_id
    AND client_record.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF existing_client.display_name = p_display_name THEN RETURN existing_client.id; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different client' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.clients (organization_id, display_name, idempotency_key)
  VALUES (p_organization_id, p_display_name, p_idempotency_key)
  RETURNING id INTO created_client_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', actor_membership_id, 'client.created', 'client',
    created_client_id, 'success', p_request_id,
    jsonb_build_object('display_name', p_display_name)
  );

  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'client.created', 1, 'client:' || created_client_id::text,
    jsonb_build_object('client_id', created_client_id)
  );

  RETURN created_client_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_clients(p_organization_id uuid)
RETURNS TABLE (id uuid, display_name text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id
      AND membership.user_id = auth.uid()
      AND membership.status = 'active'
      AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant')
  ) THEN
    RAISE EXCEPTION 'client read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT client_record.id, client_record.display_name, client_record.created_at
  FROM public.clients AS client_record
  WHERE client_record.organization_id = p_organization_id
  ORDER BY client_record.created_at DESC, client_record.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.create_client(uuid, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_clients(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_client(uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_clients(uuid) TO authenticated;
