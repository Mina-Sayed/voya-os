-- Structural tenant-integrity regressions for every tenant-owned relationship
-- found by the production-readiness catalog audit.
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing text[];
  v_unqualified text[];
BEGIN
  SELECT array_agg(expected.name ORDER BY expected.name)
  INTO v_missing
  FROM unnest(ARRAY[
    'crm_contact_method_lead_tenant_fk',
    'crm_contact_method_client_tenant_fk',
    'crm_consent_contact_method_tenant_fk',
    'whatsapp_conversation_contact_method_tenant_fk',
    'whatsapp_conversation_lead_tenant_fk',
    'whatsapp_conversation_client_tenant_fk',
    'whatsapp_message_conversation_tenant_fk',
    'whatsapp_note_conversation_tenant_fk',
    'operations_task_booking_tenant_fk'
  ]) AS expected(name)
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_constraint AS constraint_record
    WHERE constraint_record.conname = expected.name
      AND constraint_record.contype = 'f'
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'tenant-qualified foreign keys are missing: %', v_missing;
  END IF;

  SELECT array_agg(constraint_record.conname ORDER BY constraint_record.conname)
  INTO v_unqualified
  FROM pg_constraint AS constraint_record
  WHERE constraint_record.contype = 'f'
    AND constraint_record.connamespace = 'public'::regnamespace
    AND EXISTS (
      SELECT 1 FROM pg_attribute AS child_column
      WHERE child_column.attrelid = constraint_record.conrelid
        AND child_column.attname = 'organization_id'
        AND NOT child_column.attisdropped
    )
    AND EXISTS (
      SELECT 1 FROM pg_attribute AS parent_column
      WHERE parent_column.attrelid = constraint_record.confrelid
        AND parent_column.attname = 'organization_id'
        AND NOT parent_column.attisdropped
    )
    AND NOT EXISTS (
      SELECT 1
      FROM unnest(constraint_record.conkey, constraint_record.confkey)
        AS key_pair(child_attnum, parent_attnum)
      JOIN pg_attribute AS child_column
        ON child_column.attrelid = constraint_record.conrelid
       AND child_column.attnum = key_pair.child_attnum
      JOIN pg_attribute AS parent_column
        ON parent_column.attrelid = constraint_record.confrelid
       AND parent_column.attnum = key_pair.parent_attnum
      WHERE child_column.attname = 'organization_id'
        AND parent_column.attname = 'organization_id'
    );

  IF v_unqualified IS NOT NULL THEN
    RAISE EXCEPTION 'tenant-owned foreign keys remain unqualified: %', v_unqualified;
  END IF;
END;
$$;

BEGIN;

INSERT INTO public.leads (
  id, organization_id, title, source, status, idempotency_key
) VALUES (
  'bbbbbbbb-0000-0000-0000-000000000101',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'Tenant B integrity lead', 'test', 'new', 'tenant-integrity-b-lead'
);

INSERT INTO public.crm_contact_methods (
  id, organization_id, client_id, kind, normalized_value, display_value,
  idempotency_key, created_by_membership_id
) VALUES (
  'bbbbbbbb-0000-0000-0000-000000000102',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'bbbbbbbb-0000-0000-0000-000000000002',
  'email', 'tenant-b-integrity@example.test', 'tenant-b-integrity@example.test',
  'tenant-integrity-b-contact',
  (SELECT id FROM public.organization_memberships
   WHERE organization_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
     AND user_id = '22222222-2222-2222-2222-222222222222')
);

INSERT INTO public.whatsapp_channels (
  id, organization_id, provider, external_channel_id, display_name,
  created_by_membership_id
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000103',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'tenant_integrity', 'tenant-integrity-a', 'Tenant A integrity channel',
  (SELECT id FROM public.organization_memberships
   WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     AND user_id = '11111111-1111-1111-1111-111111111111')
), (
  'bbbbbbbb-0000-0000-0000-000000000103',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'tenant_integrity', 'tenant-integrity-b', 'Tenant B integrity channel',
  (SELECT id FROM public.organization_memberships
   WHERE organization_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
     AND user_id = '22222222-2222-2222-2222-222222222222')
);

INSERT INTO public.whatsapp_conversations (
  id, organization_id, channel_id, contact_method_id,
  external_conversation_key
) VALUES (
  'bbbbbbbb-0000-0000-0000-000000000104',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'bbbbbbbb-0000-0000-0000-000000000103',
  'bbbbbbbb-0000-0000-0000-000000000102',
  'tenant-integrity-b-conversation'
);

INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out
) VALUES (
  'bbbbbbbb-0000-0000-0000-000000000105',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'bbbbbbbb-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000002',
  'draft', DATE '2040-01-01', DATE '2040-01-02'
);

DO $$
DECLARE
  v_actor uuid := (
    SELECT id FROM public.organization_memberships
    WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND user_id = '11111111-1111-1111-1111-111111111111'
  );
BEGIN
  BEGIN
    INSERT INTO public.crm_contact_methods (
      organization_id, lead_id, kind, normalized_value, display_value,
      idempotency_key, created_by_membership_id
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'bbbbbbbb-0000-0000-0000-000000000101',
      'email', 'cross-lead@example.test', 'cross-lead@example.test',
      'tenant-integrity-cross-lead', v_actor
    );
    RAISE EXCEPTION 'cross-tenant contact-to-lead reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.crm_contact_methods (
      organization_id, client_id, kind, normalized_value, display_value,
      idempotency_key, created_by_membership_id
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'bbbbbbbb-0000-0000-0000-000000000002',
      'email', 'cross-client@example.test', 'cross-client@example.test',
      'tenant-integrity-cross-client', v_actor
    );
    RAISE EXCEPTION 'cross-tenant contact-to-client reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.crm_consent_events (
      organization_id, contact_method_id, consent_scope, status, source,
      created_by_membership_id
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'bbbbbbbb-0000-0000-0000-000000000102',
      'service', 'unknown', 'test', v_actor
    );
    RAISE EXCEPTION 'cross-tenant consent-to-contact reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.whatsapp_conversations (
      organization_id, channel_id, contact_method_id, external_conversation_key
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000103',
      'bbbbbbbb-0000-0000-0000-000000000102',
      'tenant-integrity-cross-contact'
    );
    RAISE EXCEPTION 'cross-tenant conversation-to-contact reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.whatsapp_conversations (
      organization_id, channel_id, lead_id, external_conversation_key
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000103',
      'bbbbbbbb-0000-0000-0000-000000000101',
      'tenant-integrity-cross-lead'
    );
    RAISE EXCEPTION 'cross-tenant conversation-to-lead reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.whatsapp_conversations (
      organization_id, channel_id, client_id, external_conversation_key
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000103',
      'bbbbbbbb-0000-0000-0000-000000000002',
      'tenant-integrity-cross-client'
    );
    RAISE EXCEPTION 'cross-tenant conversation-to-client reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.whatsapp_message_events (
      organization_id, conversation_id, event_key, direction, body_text,
      delivery_status, created_by_membership_id
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'bbbbbbbb-0000-0000-0000-000000000104',
      'tenant-integrity-cross-message', 'outbound', 'رفض', 'queued', v_actor
    );
    RAISE EXCEPTION 'cross-tenant message-to-conversation reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.whatsapp_internal_notes (
      organization_id, conversation_id, note_text, created_by_membership_id
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'bbbbbbbb-0000-0000-0000-000000000104',
      'رفض', v_actor
    );
    RAISE EXCEPTION 'cross-tenant note-to-conversation reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.operations_tasks (
      organization_id, task_type, title, booking_id,
      created_by_membership_id, idempotency_key
    ) VALUES (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'integrity', 'Cross-tenant booking task',
      'bbbbbbbb-0000-0000-0000-000000000105',
      v_actor, 'tenant-integrity-cross-booking'
    );
    RAISE EXCEPTION 'cross-tenant task-to-booking reference was accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END;
$$;

ROLLBACK;

SELECT 'tenant integrity remediation tests passed' AS result;
