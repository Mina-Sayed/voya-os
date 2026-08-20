-- Filtered audit activity remains tenant- and role-scoped while exposing only
-- redacted event details.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.audit_events', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated must not receive direct audit reads';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.list_audit_activity_filtered(uuid, integer, timestamptz, timestamptz, uuid, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must receive the filtered audit RPC';
  END IF;
END;
$$;

INSERT INTO public.audit_events (
  id, organization_id, actor_type, actor_membership_id, action,
  resource_type, resource_id, outcome, reason_code, before_delta, after_delta
)
SELECT
  'aaaaaaaa-0000-0000-0000-0000000000f8',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'user', membership.id, 'property.updated', 'property',
  'aaaaaaaa-0000-0000-0000-000000000001', 'success', 'user_edit',
  jsonb_build_object('name', 'قديم'), jsonb_build_object('name', 'جديد')
FROM public.organization_memberships AS membership
WHERE membership.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND membership.user_id = '11111111-1111-1111-1111-111111111111';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT * FROM public.list_audit_activity_filtered(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 20,
  '2026-08-16 00:00:00+00', '2026-08-17 23:59:59+00',
  (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'),
  'property.updated', 'property'
);

DO $$
DECLARE
  v_event record;
BEGIN
  SELECT * INTO v_event FROM public.list_audit_activity_filtered(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 20,
    '2026-08-16 00:00:00+00', '2026-08-17 23:59:59+00', NULL,
    'property.updated', 'property'
  );
  IF v_event.action <> 'property.updated' OR v_event.actor_display_name <> 'Tenant A user'
    OR v_event.after_delta ->> 'name' <> 'جديد' OR v_event.reason_code <> 'user_edit' THEN
    RAISE EXCEPTION 'filtered audit event must include redacted actor and change details';
  END IF;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_audit_activity_filtered('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 20, NULL, NULL, NULL, NULL, NULL);
    RAISE EXCEPTION 'suspended viewer must not read filtered audit activity';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'filtered audit activity database integration tests passed' AS result;
