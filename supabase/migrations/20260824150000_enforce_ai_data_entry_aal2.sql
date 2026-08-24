-- Require MFA assurance level 2 at the database boundary for every
-- authenticated AI data-entry RPC. The workspace UI already enforces MFA,
-- but PostgREST RPCs are independently callable by authenticated JWTs.
--
-- Preserve the exact existing business logic by renaming the current functions
-- to private unchecked implementations, revoking their grants, and exposing
-- thin wrappers under the original names. The wrappers add only the AAL2 gate.

CREATE OR REPLACE FUNCTION public.ai_data_entry_require_aal2_v1()
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
BEGIN
  IF coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' THEN
    RAISE EXCEPTION 'AI data-entry requires MFA assurance level 2' USING ERRCODE = '42501';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.ai_data_entry_require_aal2_v1() FROM PUBLIC, anon, authenticated, service_role;

ALTER FUNCTION public.create_ai_data_entry_draft_v1(uuid,text,text,uuid)
  RENAME TO create_ai_data_entry_draft_v1_unchecked;
ALTER FUNCTION public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid)
  RENAME TO register_ai_data_entry_input_v1_unchecked;
ALTER FUNCTION public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid)
  RENAME TO submit_ai_data_entry_draft_v1_unchecked;
ALTER FUNCTION public.list_ai_data_entry_drafts_v1(uuid,integer)
  RENAME TO list_ai_data_entry_drafts_v1_unchecked;
ALTER FUNCTION public.get_ai_data_entry_draft_v1(uuid,uuid)
  RENAME TO get_ai_data_entry_draft_v1_unchecked;
ALTER FUNCTION public.list_ai_data_entry_inputs_v1(uuid,uuid)
  RENAME TO list_ai_data_entry_inputs_v1_unchecked;
ALTER FUNCTION public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid)
  RENAME TO claim_ai_data_entry_confirmation_v3_unchecked;
ALTER FUNCTION public.reject_ai_data_entry_draft_v1(uuid,uuid,integer,text,uuid)
  RENAME TO reject_ai_data_entry_draft_v1_unchecked;

REVOKE ALL ON FUNCTION public.create_ai_data_entry_draft_v1_unchecked(uuid,text,text,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.register_ai_data_entry_input_v1_unchecked(uuid,uuid,text,text,bigint,text,text,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.submit_ai_data_entry_draft_v1_unchecked(uuid,uuid,text,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_ai_data_entry_drafts_v1_unchecked(uuid,integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_ai_data_entry_draft_v1_unchecked(uuid,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_ai_data_entry_inputs_v1_unchecked(uuid,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.claim_ai_data_entry_confirmation_v3_unchecked(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.reject_ai_data_entry_draft_v1_unchecked(uuid,uuid,integer,text,uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_source_text text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.ai_data_entry_require_aal2_v1();
  RETURN public.create_ai_data_entry_draft_v1_unchecked(
    p_organization_id, p_source_text, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.register_ai_data_entry_input_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_checksum_sha256 text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.ai_data_entry_require_aal2_v1();
  RETURN public.register_ai_data_entry_input_v1_unchecked(
    p_organization_id, p_draft_id, p_storage_path, p_mime_type, p_byte_size,
    p_checksum_sha256, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.ai_data_entry_require_aal2_v1();
  RETURN public.submit_ai_data_entry_draft_v1_unchecked(
    p_organization_id, p_draft_id, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_ai_data_entry_drafts_v1(
  p_organization_id uuid,
  p_limit integer DEFAULT 30
)
RETURNS TABLE (
  id uuid, ai_run_id uuid, status text, source_kind text, version integer,
  error_code text, expires_at timestamptz, created_at timestamptz,
  updated_at timestamptz, created_by_membership_id uuid, input_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.ai_data_entry_require_aal2_v1();
  RETURN QUERY SELECT *
  FROM public.list_ai_data_entry_drafts_v1_unchecked(p_organization_id, p_limit);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_draft_id uuid
)
RETURNS TABLE (
  id uuid, ai_run_id uuid, status text, source_text text, source_kind text,
  extraction_payload jsonb, confirmation_payload jsonb, application_result jsonb,
  error_code text, version integer, expires_at timestamptz,
  created_at timestamptz, updated_at timestamptz, created_by_membership_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.ai_data_entry_require_aal2_v1();
  RETURN QUERY SELECT *
  FROM public.get_ai_data_entry_draft_v1_unchecked(p_organization_id, p_draft_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.list_ai_data_entry_inputs_v1(
  p_organization_id uuid,
  p_draft_id uuid
)
RETURNS TABLE (
  id uuid, storage_bucket text, storage_path text, mime_type text,
  byte_size bigint, checksum_sha256 text, status text, mapped_property_id uuid,
  mapped_at timestamptz, created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.ai_data_entry_require_aal2_v1();
  RETURN QUERY SELECT *
  FROM public.list_ai_data_entry_inputs_v1_unchecked(p_organization_id, p_draft_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_ai_data_entry_confirmation_v3(
  p_organization_id uuid,
  p_draft_id uuid,
  p_confirmation_payload jsonb,
  p_excluded_client_indexes integer[],
  p_excluded_property_indexes integer[],
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS TABLE (
  outcome text,
  execution_token uuid,
  draft_version integer,
  application_result jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.ai_data_entry_require_aal2_v1();
  RETURN QUERY SELECT *
  FROM public.claim_ai_data_entry_confirmation_v3_unchecked(
    p_organization_id, p_draft_id, p_confirmation_payload,
    p_excluded_client_indexes, p_excluded_property_indexes, p_expected_version,
    p_idempotency_key, p_request_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_ai_data_entry_draft_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.ai_data_entry_require_aal2_v1();
  RETURN public.reject_ai_data_entry_draft_v1_unchecked(
    p_organization_id, p_draft_id, p_expected_version, p_idempotency_key, p_request_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_ai_data_entry_draft_v1(uuid,text,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_ai_data_entry_drafts_v1(uuid,integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_ai_data_entry_draft_v1(uuid,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_ai_data_entry_inputs_v1(uuid,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reject_ai_data_entry_draft_v1(uuid,uuid,integer,text,uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_ai_data_entry_draft_v1(uuid,text,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_ai_data_entry_input_v1(uuid,uuid,text,text,bigint,text,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_ai_data_entry_draft_v1(uuid,uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_ai_data_entry_drafts_v1(uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_ai_data_entry_draft_v1(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_ai_data_entry_inputs_v1(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_ai_data_entry_confirmation_v3(uuid,uuid,jsonb,integer[],integer[],integer,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_ai_data_entry_draft_v1(uuid,uuid,integer,text,uuid) TO authenticated;
