-- Require workspace MFA AAL2 at every authenticated booking and approval
-- boundary, including older callable read/write alternatives.

ALTER FUNCTION public.create_commercial_booking_draft(uuid, uuid, uuid, date, date, text, text, text, uuid)
  RENAME TO create_commercial_booking_draft_without_review_aal2;
ALTER FUNCTION public.request_commercial_booking_approval(uuid, uuid, text, uuid)
  RENAME TO request_commercial_booking_approval_without_review_aal2;
ALTER FUNCTION public.request_booking_amendment(uuid, uuid, uuid, uuid, date, date, text, text, text, text, uuid)
  RENAME TO request_booking_amendment_without_review_aal2;
ALTER FUNCTION public.execute_booking_amendment(uuid, uuid, uuid, text, uuid)
  RENAME TO execute_booking_amendment_without_review_aal2;
ALTER FUNCTION public.decide_booking_approval(uuid, uuid, text, text, uuid)
  RENAME TO decide_booking_approval_without_review_aal2;
ALTER FUNCTION public.cancel_booking_draft(uuid, uuid, text, text, uuid)
  RENAME TO cancel_booking_draft_without_review_aal2;
ALTER FUNCTION public.request_booking_cancellation(uuid, uuid, text, text, uuid)
  RENAME TO request_booking_cancellation_without_review_aal2;
ALTER FUNCTION public.execute_booking_cancellation(uuid, uuid, text, uuid)
  RENAME TO execute_booking_cancellation_without_review_aal2;
ALTER FUNCTION public.list_executable_booking_changes_v1(uuid)
  RENAME TO list_executable_booking_changes_v1_without_review_aal2;
ALTER FUNCTION public.list_approval_requests_v2(uuid, integer)
  RENAME TO list_approval_requests_v2_without_review_aal2;
ALTER FUNCTION public.list_approval_requests(uuid, integer)
  RENAME TO list_approval_requests_without_review_aal2;
ALTER FUNCTION public.record_booking_stay_event(uuid, uuid, text, text, text, uuid)
  RENAME TO record_booking_stay_event_without_review_aal2;
ALTER FUNCTION public.list_booking_drafts(uuid)
  RENAME TO list_booking_drafts_without_review_aal2;
ALTER FUNCTION public.list_booking_work_queue(uuid)
  RENAME TO list_booking_work_queue_without_review_aal2;
ALTER FUNCTION public.create_booking_draft(uuid, uuid, uuid, date, date, text, uuid)
  RENAME TO create_booking_draft_without_review_aal2;

REVOKE ALL ON FUNCTION public.create_commercial_booking_draft_without_review_aal2(uuid, uuid, uuid, date, date, text, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_commercial_booking_approval_without_review_aal2(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_booking_amendment_without_review_aal2(uuid, uuid, uuid, uuid, date, date, text, text, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.execute_booking_amendment_without_review_aal2(uuid, uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.decide_booking_approval_without_review_aal2(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cancel_booking_draft_without_review_aal2(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_booking_cancellation_without_review_aal2(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.execute_booking_cancellation_without_review_aal2(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_executable_booking_changes_v1_without_review_aal2(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_approval_requests_v2_without_review_aal2(uuid, integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_approval_requests_without_review_aal2(uuid, integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_booking_stay_event_without_review_aal2(uuid, uuid, text, text, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_booking_drafts_without_review_aal2(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_booking_work_queue_without_review_aal2(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_booking_draft_without_review_aal2(uuid, uuid, uuid, date, date, text, uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.create_booking_draft(
  p_organization_id uuid, p_property_id uuid, p_client_id uuid,
  p_check_in date, p_check_out date, p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.create_booking_draft_without_review_aal2(
    p_organization_id, p_property_id, p_client_id, p_check_in, p_check_out,
    p_idempotency_key, p_request_id
  );
END;
$$;

CREATE FUNCTION public.create_commercial_booking_draft(
  p_organization_id uuid, p_property_id uuid, p_client_id uuid, p_check_in date,
  p_check_out date, p_amount_minor text, p_currency text, p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.create_commercial_booking_draft_without_review_aal2(
    p_organization_id, p_property_id, p_client_id, p_check_in, p_check_out,
    p_amount_minor, p_currency, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE FUNCTION public.request_commercial_booking_approval(
  p_organization_id uuid, p_booking_id uuid, p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.request_commercial_booking_approval_without_review_aal2(
    p_organization_id, p_booking_id, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE FUNCTION public.request_booking_amendment(
  p_organization_id uuid, p_booking_id uuid, p_property_id uuid, p_client_id uuid,
  p_check_in date, p_check_out date, p_amount_minor text, p_currency text,
  p_reason text, p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.request_booking_amendment_without_review_aal2(
    p_organization_id, p_booking_id, p_property_id, p_client_id, p_check_in,
    p_check_out, p_amount_minor, p_currency, p_reason, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE FUNCTION public.execute_booking_amendment(
  p_organization_id uuid, p_booking_id uuid, p_approval_request_id uuid,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.execute_booking_amendment_without_review_aal2(
    p_organization_id, p_booking_id, p_approval_request_id, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE FUNCTION public.decide_booking_approval(
  p_organization_id uuid, p_approval_request_id uuid, p_decision text,
  p_reason text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.decide_booking_approval_without_review_aal2(
    p_organization_id, p_approval_request_id, p_decision, p_reason, p_request_id
  );
END;
$$;

CREATE FUNCTION public.cancel_booking_draft(
  p_organization_id uuid, p_booking_id uuid, p_reason text,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.cancel_booking_draft_without_review_aal2(
    p_organization_id, p_booking_id, p_reason, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE FUNCTION public.request_booking_cancellation(
  p_organization_id uuid, p_booking_id uuid, p_reason text,
  p_idempotency_key text, p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.request_booking_cancellation_without_review_aal2(
    p_organization_id, p_booking_id, p_reason, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE FUNCTION public.execute_booking_cancellation(
  p_organization_id uuid, p_booking_id uuid, p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.execute_booking_cancellation_without_review_aal2(
    p_organization_id, p_booking_id, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE FUNCTION public.list_executable_booking_changes_v1(p_organization_id uuid)
RETURNS TABLE (
  booking_id uuid, approval_request_id uuid, proposed_action text,
  expires_at timestamptz, created_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT *
  FROM public.list_executable_booking_changes_v1_without_review_aal2(p_organization_id);
END;
$$;

CREATE FUNCTION public.list_approval_requests_v2(p_organization_id uuid, p_limit integer DEFAULT 50)
RETURNS TABLE (
  id uuid, resource_type text, resource_id uuid, proposed_action text,
  status text, expires_at timestamptz, created_at timestamptz,
  proposal_summary jsonb, requester_display_name text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_approval_requests_v2_without_review_aal2(p_organization_id, p_limit);
END;
$$;

CREATE FUNCTION public.list_approval_requests(p_organization_id uuid, p_limit integer DEFAULT 50)
RETURNS TABLE (
  id uuid, resource_type text, resource_id uuid, proposed_action text,
  status text, expires_at timestamptz, created_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_approval_requests_without_review_aal2(p_organization_id, p_limit);
END;
$$;

CREATE FUNCTION public.record_booking_stay_event(
  p_organization_id uuid, p_booking_id uuid, p_event_type text,
  p_notes text DEFAULT NULL, p_idempotency_key text DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN public.record_booking_stay_event_without_review_aal2(
    p_organization_id, p_booking_id, p_event_type, p_notes, p_idempotency_key, p_request_id
  );
END;
$$;

CREATE FUNCTION public.list_booking_drafts(p_organization_id uuid)
RETURNS TABLE (
  id uuid, property_id uuid, property_code text, property_name text,
  client_id uuid, client_name text, status text, check_in date,
  check_out date, created_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_booking_drafts_without_review_aal2(p_organization_id);
END;
$$;

CREATE FUNCTION public.list_booking_work_queue(p_organization_id uuid)
RETURNS TABLE (
  id uuid, property_code text, property_name text, client_name text,
  status text, check_in date, check_out date, has_check_in boolean,
  has_check_out boolean, created_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
BEGIN
  PERFORM public.require_workspace_aal2_v1();
  RETURN QUERY SELECT * FROM public.list_booking_work_queue_without_review_aal2(p_organization_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_commercial_booking_draft(uuid, uuid, uuid, date, date, text, text, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.request_commercial_booking_approval(uuid, uuid, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.request_booking_amendment(uuid, uuid, uuid, uuid, date, date, text, text, text, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.execute_booking_amendment(uuid, uuid, uuid, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.decide_booking_approval(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.cancel_booking_draft(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.request_booking_cancellation(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.execute_booking_cancellation(uuid, uuid, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_executable_booking_changes_v1(uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_approval_requests_v2(uuid, integer) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_approval_requests(uuid, integer) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.record_booking_stay_event(uuid, uuid, text, text, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_booking_drafts(uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_booking_work_queue(uuid) FROM PUBLIC, anon, service_role;

GRANT EXECUTE ON FUNCTION public.create_commercial_booking_draft(uuid, uuid, uuid, date, date, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_commercial_booking_approval(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_booking_amendment(uuid, uuid, uuid, uuid, date, date, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.execute_booking_amendment(uuid, uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decide_booking_approval(uuid, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_booking_draft(uuid, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_booking_cancellation(uuid, uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.execute_booking_cancellation(uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_executable_booking_changes_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_approval_requests_v2(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_approval_requests(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_booking_stay_event(uuid, uuid, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_booking_drafts(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_booking_work_queue(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.create_booking_draft(uuid, uuid, uuid, date, date, text, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_booking_draft(uuid, uuid, uuid, date, date, text, uuid) TO authenticated;
