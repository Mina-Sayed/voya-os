-- Fetch-limit-plus-one page reads and their matching detail RPCs share a bound.
\set ON_ERROR_STOP on

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT set_config('request.jwt.claim.aal', 'aal2', false);

DO $$
DECLARE
  v_ids uuid[] := array_fill('aaaaaaaa-0000-0000-0000-000000000001'::uuid, ARRAY[101]);
  v_oversized_ids uuid[] := array_fill('aaaaaaaa-0000-0000-0000-000000000001'::uuid, ARRAY[102]);
BEGIN
  PERFORM 1 FROM public.list_lead_page_details_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_ids
  );
  PERFORM 1 FROM public.list_property_image_ids_v1(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_ids
  );

  BEGIN
    PERFORM 1 FROM public.list_lead_page_details_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_oversized_ids
    );
    RAISE EXCEPTION 'lead detail batches above the fetch limit must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    IF SQLERRM <> 'lead detail batch is invalid' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM 1 FROM public.list_property_image_ids_v1(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_oversized_ids
    );
    RAISE EXCEPTION 'property image batches above the fetch limit must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    IF SQLERRM <> 'property image batch is invalid' THEN RAISE; END IF;
  END;
END;
$$;
RESET ROLE;

SELECT 'workspace page and detail batch limits agree' AS result;
