-- Close the remaining property-bearing workspace entry points at the
-- database boundary. The first property AAL2 migration covered the property,
-- owner, and image RPC families, but availability and indirect property reads
-- still accepted an authenticated AAL1 session.
--
-- Keep the public signatures stable for existing Server Actions/PostgREST
-- callers. The old implementations remain private, while narrow wrappers
-- enforce the same database-owned MFA boundary before delegating. Worker and
-- service-role execution stays explicitly out of these human workspace paths.

ALTER FUNCTION public.create_availability_block(
  uuid, uuid, date, date, text, text, text, uuid
) RENAME TO create_availability_block_without_workspace_aal2;

ALTER FUNCTION public.list_availability_blocks(uuid)
  RENAME TO list_availability_blocks_without_workspace_aal2;

ALTER FUNCTION public.list_commercial_booking_work_queue(uuid)
  RENAME TO list_commercial_booking_work_queue_without_workspace_aal2;

ALTER FUNCTION public.list_whatsapp_conversations_ai_v1(uuid)
  RENAME TO list_whatsapp_conversations_ai_v1_without_workspace_aal2;

ALTER FUNCTION public.claim_whatsapp_property_confirmation_v1(
  uuid, uuid, jsonb, integer, text, uuid
) RENAME TO claim_whatsapp_property_confirmation_v1_without_workspace_aal2;

ALTER FUNCTION public.finalize_whatsapp_property_confirmation_v1(
  uuid, uuid, uuid, uuid, uuid, text, jsonb, uuid
) RENAME TO finalize_whatsapp_property_confirmation_v1_without_workspace_aal2;

REVOKE ALL ON FUNCTION public.create_availability_block_without_workspace_aal2(
  uuid, uuid, date, date, text, text, text, uuid
) FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker;
REVOKE ALL ON FUNCTION public.list_availability_blocks_without_workspace_aal2(uuid)
  FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker;
REVOKE ALL ON FUNCTION public.list_commercial_booking_work_queue_without_workspace_aal2(uuid)
  FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker;
REVOKE ALL ON FUNCTION public.list_whatsapp_conversations_ai_v1_without_workspace_aal2(uuid)
  FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker;
REVOKE ALL ON FUNCTION public.claim_whatsapp_property_confirmation_v1_without_workspace_aal2(
  uuid, uuid, jsonb, integer, text, uuid
) FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker;
REVOKE ALL ON FUNCTION public.finalize_whatsapp_property_confirmation_v1_without_workspace_aal2(
  uuid, uuid, uuid, uuid, uuid, text, jsonb, uuid
) FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker;

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
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.create_availability_block_without_workspace_aal2(
    p_organization_id, p_property_id, p_start_date, p_end_date,
    p_block_type, p_reason, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_availability_blocks(
  p_organization_id uuid
)
RETURNS TABLE (
  id uuid,
  property_id uuid,
  start_date date,
  end_date date,
  block_type text,
  reason text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY
  SELECT *
  FROM public.list_availability_blocks_without_workspace_aal2(p_organization_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.list_commercial_booking_work_queue(
  p_organization_id uuid
)
RETURNS TABLE (
  id uuid,
  property_code text,
  property_name text,
  client_name text,
  status text,
  check_in date,
  check_out date,
  agreed_total_amount_minor text,
  currency text,
  commercial_completion_status text,
  version integer,
  has_check_in boolean,
  has_check_out boolean,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY
  SELECT *
  FROM public.list_commercial_booking_work_queue_without_workspace_aal2(p_organization_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.list_whatsapp_conversations_ai_v1(
  p_organization_id uuid
)
RETURNS TABLE (
  id uuid,
  channel_id uuid,
  channel_name text,
  contact_label text,
  status text,
  assigned_membership_id uuid,
  last_message_at timestamptz,
  last_message_preview text,
  last_message_direction text,
  ai_enabled boolean,
  conversation_type text,
  lead_id uuid,
  client_id uuid,
  property_owner_id uuid,
  property_id uuid,
  structured_state jsonb,
  last_customer_message_at timestamptz,
  last_ai_message_at timestamptz,
  next_follow_up_at timestamptz,
  ai_state_version integer,
  recent_messages jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY
  SELECT *
  FROM public.list_whatsapp_conversations_ai_v1_without_workspace_aal2(p_organization_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_whatsapp_property_confirmation_v1(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_confirmation_payload jsonb,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS TABLE (
  outcome text,
  confirmation_token uuid,
  conversation_version integer,
  confirmation_payload jsonb,
  confirmation_result jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY
  SELECT *
  FROM public.claim_whatsapp_property_confirmation_v1_without_workspace_aal2(
    p_organization_id, p_conversation_id, p_confirmation_payload,
    p_expected_version, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_whatsapp_property_confirmation_v1(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_confirmation_token uuid,
  p_property_owner_id uuid,
  p_property_id uuid,
  p_status text,
  p_confirmation_result jsonb,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.finalize_whatsapp_property_confirmation_v1_without_workspace_aal2(
    p_organization_id, p_conversation_id, p_confirmation_token,
    p_property_owner_id, p_property_id, p_status, p_confirmation_result,
    p_request_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_availability_block(
  uuid, uuid, date, date, text, text, text, uuid
) FROM PUBLIC, anon, service_role, voya_outbox_worker;
REVOKE ALL ON FUNCTION public.list_availability_blocks(uuid)
  FROM PUBLIC, anon, service_role, voya_outbox_worker;
REVOKE ALL ON FUNCTION public.list_commercial_booking_work_queue(uuid)
  FROM PUBLIC, anon, service_role, voya_outbox_worker;
REVOKE ALL ON FUNCTION public.list_whatsapp_conversations_ai_v1(uuid)
  FROM PUBLIC, anon, service_role, voya_outbox_worker;
REVOKE ALL ON FUNCTION public.claim_whatsapp_property_confirmation_v1(
  uuid, uuid, jsonb, integer, text, uuid
) FROM PUBLIC, anon, service_role, voya_outbox_worker;
REVOKE ALL ON FUNCTION public.finalize_whatsapp_property_confirmation_v1(
  uuid, uuid, uuid, uuid, uuid, text, jsonb, uuid
) FROM PUBLIC, anon, service_role, voya_outbox_worker;

GRANT EXECUTE ON FUNCTION public.create_availability_block(
  uuid, uuid, date, date, text, text, text, uuid
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_availability_blocks(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_commercial_booking_work_queue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_whatsapp_conversations_ai_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_whatsapp_property_confirmation_v1(
  uuid, uuid, jsonb, integer, text, uuid
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_whatsapp_property_confirmation_v1(
  uuid, uuid, uuid, uuid, uuid, text, jsonb, uuid
) TO authenticated;
