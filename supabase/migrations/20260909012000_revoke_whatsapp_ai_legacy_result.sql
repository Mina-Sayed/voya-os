-- Keep the WhatsApp AI result safety policy at the only worker entry point.
--
-- 20260905030000_harden_whatsapp_ai_p1_killswitch.sql retained the original
-- implementation as a legacy helper, but also granted it directly to the
-- worker and service_role. That allowed callers to opt out of the wrapper's
-- current-channel and low-confidence reply checks. The helper remains
-- available to the guarded wrapper as a SECURITY DEFINER owner call; it is
-- not an RPC surface for either worker role.

ALTER FUNCTION public.apply_whatsapp_ai_result_v1_legacy(
  uuid, text, text, jsonb, text, text, text, boolean
) SET search_path = pg_catalog;

REVOKE ALL ON FUNCTION public.apply_whatsapp_ai_result_v1_legacy(
  uuid, text, text, jsonb, text, text, text, boolean
) FROM PUBLIC, anon, authenticated, voya_outbox_worker, service_role;

REVOKE ALL ON FUNCTION public.apply_whatsapp_ai_result_v1(
  uuid, text, text, jsonb, text, text, text, boolean
) FROM PUBLIC, anon, authenticated, voya_outbox_worker, service_role;

GRANT EXECUTE ON FUNCTION public.apply_whatsapp_ai_result_v1(
  uuid, text, text, jsonb, text, text, text, boolean
) TO voya_outbox_worker, service_role;
