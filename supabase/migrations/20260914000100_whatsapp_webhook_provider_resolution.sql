-- Resolve the configured Meta provider without exposing whatsapp_channels through PostgREST.
-- The webhook route is service-role-only; keep the lookup behind the same narrow boundary.

CREATE OR REPLACE FUNCTION public.resolve_whatsapp_webhook_provider_v1(
  p_external_channel_id text,
  p_preferred_provider text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_external_channel_id text := btrim(p_external_channel_id);
  v_preferred_provider text := nullif(btrim(p_preferred_provider), '');
  v_provider text;
  v_provider_count integer;
BEGIN
  IF p_external_channel_id IS NULL
    OR char_length(v_external_channel_id) NOT BETWEEN 1 AND 256
    OR (v_preferred_provider IS NOT NULL AND v_preferred_provider NOT IN ('meta_cloud', 'meta_cloud_sandbox')) THEN
    RAISE EXCEPTION 'webhook provider lookup input is invalid' USING ERRCODE = '22023';
  END IF;

  IF v_preferred_provider IS NOT NULL THEN
    SELECT channel.provider
      INTO v_provider
    FROM public.whatsapp_channels AS channel
    WHERE channel.external_channel_id = v_external_channel_id
      AND channel.provider = v_preferred_provider
      AND channel.provider IN ('meta_cloud', 'meta_cloud_sandbox')
      AND channel.status = 'active'
      AND channel.kill_switch = false
    LIMIT 1;

    IF v_provider IS NOT NULL THEN
      RETURN v_provider;
    END IF;
  END IF;

  SELECT count(DISTINCT channel.provider), min(channel.provider)
    INTO v_provider_count, v_provider
  FROM public.whatsapp_channels AS channel
  WHERE channel.external_channel_id = v_external_channel_id
    AND channel.provider IN ('meta_cloud', 'meta_cloud_sandbox')
    AND channel.status = 'active'
    AND channel.kill_switch = false;

  IF v_provider_count <> 1 OR v_provider IS NULL THEN
    RAISE EXCEPTION 'webhook channel provider is unavailable or ambiguous' USING ERRCODE = '42501';
  END IF;

  RETURN v_provider;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_whatsapp_webhook_provider_v1(text, text) FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_whatsapp_webhook_provider_v1(text, text) TO service_role;
