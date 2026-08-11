-- Read-only preflight for migration 20260803085546. It reports no row data and
-- aborts when existing tenant references or active fleet allocations violate
-- the invariants that the forward migration will enforce.
\set ON_ERROR_STOP on

BEGIN TRANSACTION READ ONLY;

DO $$
DECLARE
  v_cross_tenant bigint;
  v_vehicle_overlaps bigint;
  v_driver_overlaps bigint;
BEGIN
  SELECT coalesce(sum(check_result.violations), 0)
  INTO v_cross_tenant
  FROM (
    SELECT count(*) AS violations
    FROM public.crm_contact_methods AS child
    JOIN public.leads AS parent ON parent.id = child.lead_id
    WHERE child.organization_id <> parent.organization_id
    UNION ALL
    SELECT count(*)
    FROM public.crm_contact_methods AS child
    JOIN public.clients AS parent ON parent.id = child.client_id
    WHERE child.organization_id <> parent.organization_id
    UNION ALL
    SELECT count(*)
    FROM public.crm_consent_events AS child
    JOIN public.crm_contact_methods AS parent ON parent.id = child.contact_method_id
    WHERE child.organization_id <> parent.organization_id
    UNION ALL
    SELECT count(*)
    FROM public.whatsapp_conversations AS child
    JOIN public.crm_contact_methods AS parent ON parent.id = child.contact_method_id
    WHERE child.organization_id <> parent.organization_id
    UNION ALL
    SELECT count(*)
    FROM public.whatsapp_conversations AS child
    JOIN public.leads AS parent ON parent.id = child.lead_id
    WHERE child.organization_id <> parent.organization_id
    UNION ALL
    SELECT count(*)
    FROM public.whatsapp_conversations AS child
    JOIN public.clients AS parent ON parent.id = child.client_id
    WHERE child.organization_id <> parent.organization_id
    UNION ALL
    SELECT count(*)
    FROM public.whatsapp_message_events AS child
    JOIN public.whatsapp_conversations AS parent ON parent.id = child.conversation_id
    WHERE child.organization_id <> parent.organization_id
    UNION ALL
    SELECT count(*)
    FROM public.whatsapp_internal_notes AS child
    JOIN public.whatsapp_conversations AS parent ON parent.id = child.conversation_id
    WHERE child.organization_id <> parent.organization_id
    UNION ALL
    SELECT count(*)
    FROM public.operations_tasks AS child
    JOIN public.bookings AS parent ON parent.id = child.booking_id
    WHERE child.organization_id <> parent.organization_id
  ) AS check_result;

  SELECT count(*)
  INTO v_vehicle_overlaps
  FROM public.transport_requests AS first_request
  JOIN public.transport_requests AS second_request
    ON second_request.organization_id = first_request.organization_id
   AND second_request.vehicle_id = first_request.vehicle_id
   AND second_request.id > first_request.id
   AND second_request.status IN ('assigned', 'in_progress')
   AND tstzrange(second_request.pickup_at, second_request.return_at, '[)')
       && tstzrange(first_request.pickup_at, first_request.return_at, '[)')
  WHERE first_request.status IN ('assigned', 'in_progress')
    AND first_request.vehicle_id IS NOT NULL;

  SELECT count(*)
  INTO v_driver_overlaps
  FROM public.transport_requests AS first_request
  JOIN public.transport_requests AS second_request
    ON second_request.organization_id = first_request.organization_id
   AND second_request.driver_id = first_request.driver_id
   AND second_request.id > first_request.id
   AND second_request.status IN ('assigned', 'in_progress')
   AND tstzrange(second_request.pickup_at, second_request.return_at, '[)')
       && tstzrange(first_request.pickup_at, first_request.return_at, '[)')
  WHERE first_request.status IN ('assigned', 'in_progress')
    AND first_request.driver_id IS NOT NULL;

  IF v_cross_tenant <> 0 OR v_vehicle_overlaps <> 0 OR v_driver_overlaps <> 0 THEN
    RAISE EXCEPTION
      'production security migration preflight failed (cross_tenant=%, vehicle_overlaps=%, driver_overlaps=%)',
      v_cross_tenant, v_vehicle_overlaps, v_driver_overlaps;
  END IF;
END;
$$;

ROLLBACK;

SELECT 'production security migration preflight passed' AS result;
