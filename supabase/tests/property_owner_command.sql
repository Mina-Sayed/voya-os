-- Browser roles may create property-owner records only through this
-- authorization and audit boundary; they never receive direct table writes.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.property_owners', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated must not receive direct property owner inserts';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);

SELECT public.create_property_owner(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'New property owner',
  'owner-command-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000a0'
);

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.property_owners
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND idempotency_key = 'owner-command-a-1') <> 1 THEN
    RAISE EXCEPTION 'authorized property owner command did not persist a record';
  END IF;

  IF (SELECT count(*)
      FROM public.audit_events AS audit
      JOIN public.property_owners AS owner_record ON owner_record.id = audit.resource_id
      WHERE audit.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND audit.action = 'property_owner.created'
        AND audit.outcome = 'success'
        AND owner_record.idempotency_key = 'owner-command-a-1') <> 1 THEN
    RAISE EXCEPTION 'property owner command must append audit evidence';
  END IF;

  IF (SELECT count(*)
      FROM public.outbox_events AS outbox
      JOIN public.property_owners AS owner_record
        ON (outbox.payload ->> 'property_owner_id')::uuid = owner_record.id
      WHERE outbox.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND outbox.event_type = 'property_owner.created'
        AND owner_record.idempotency_key = 'owner-command-a-1') <> 1 THEN
    RAISE EXCEPTION 'property owner command must enqueue an outbox event atomically';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);

SELECT public.create_property_owner(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'New property owner',
  'owner-command-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000a1'
);

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.property_owners
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND idempotency_key = 'owner-command-a-1') <> 1 THEN
    RAISE EXCEPTION 'same idempotency key must not create a second property owner';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);

DO $$
BEGIN
  BEGIN
    PERFORM public.create_property_owner(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'Denied owner',
      'owner-command-denied',
      'aaaaaaaa-0000-0000-0000-0000000000a2'
    );
    RAISE EXCEPTION 'suspended viewer must not create property owners';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

RESET ROLE;
