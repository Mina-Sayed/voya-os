-- Project only booking approvals that the current owner/manager can actually execute.
-- This avoids deriving executable state from a paginated generic approval feed.

CREATE OR REPLACE FUNCTION public.list_executable_booking_changes_v1(
  p_organization_id uuid
)
RETURNS TABLE (
  booking_id uuid,
  approval_request_id uuid,
  proposed_action text,
  expires_at timestamptz,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager');

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'booking executable approval read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT DISTINCT ON (request.resource_id, request.proposed_action)
    request.resource_id,
    request.id,
    request.proposed_action,
    request.expires_at,
    request.created_at
  FROM public.approval_requests AS request
  JOIN public.bookings AS booking
    ON booking.organization_id = request.organization_id
   AND booking.id = request.resource_id
  WHERE request.organization_id = p_organization_id
    AND request.resource_type = 'booking'
    AND request.proposed_action IN ('booking.confirm', 'booking.amend')
    AND request.status = 'approved'
    AND request.expires_at IS NOT NULL
    AND request.expires_at > timezone('utc', now())
    AND request.requester_membership_id <> v_actor
    AND request.snapshot_hash = encode(extensions.digest(request.proposal_snapshot::text, 'sha256'), 'hex')
    AND (
      (
        request.proposed_action = 'booking.confirm'
        AND booking.status = 'pending_approval'
        AND EXISTS (
          SELECT 1
          FROM public.properties AS confirmation_property
          WHERE confirmation_property.organization_id = booking.organization_id
            AND confirmation_property.id = booking.property_id
            AND confirmation_property.status = 'active'
        )
        AND request.proposal_snapshot = jsonb_build_object(
          'booking_id', booking.id,
          'booking_version', booking.version,
          'property_id', booking.property_id,
          'client_id', booking.client_id,
          'check_in', booking.check_in,
          'check_out', booking.check_out,
          'agreed_total_amount_minor', booking.agreed_total_amount_minor,
          'currency', booking.currency,
          'status', 'draft'
        )
      )
      OR (
        request.proposed_action = 'booking.amend'
        AND booking.status = 'confirmed'
        AND request.proposal_snapshot->>'booking_version' ~ '^[0-9]+
      )
    )
  ORDER BY request.resource_id, request.proposed_action, request.created_at DESC, request.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_executable_booking_changes_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_executable_booking_changes_v1(uuid) TO authenticated;

        AND request.proposal_snapshot->>'property_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}
      )
    )
  ORDER BY request.resource_id, request.proposed_action, request.created_at DESC, request.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_executable_booking_changes_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_executable_booking_changes_v1(uuid) TO authenticated;

        AND request.proposal_snapshot->>'client_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}
      )
    )
  ORDER BY request.resource_id, request.proposed_action, request.created_at DESC, request.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_executable_booking_changes_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_executable_booking_changes_v1(uuid) TO authenticated;

        AND (request.proposal_snapshot->>'booking_version')::integer = booking.version
        AND EXISTS (
          SELECT 1
          FROM public.properties AS amendment_property
          WHERE amendment_property.organization_id = booking.organization_id
            AND amendment_property.id = (request.proposal_snapshot->>'property_id')::uuid
            AND amendment_property.status = 'active'
        )
        AND EXISTS (
          SELECT 1
          FROM public.clients AS amendment_client
          WHERE amendment_client.organization_id = booking.organization_id
            AND amendment_client.id = (request.proposal_snapshot->>'client_id')::uuid
            AND amendment_client.archived_at IS NULL
        )
      )
    )
  ORDER BY request.resource_id, request.proposed_action, request.created_at DESC, request.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_executable_booking_changes_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_executable_booking_changes_v1(uuid) TO authenticated;
