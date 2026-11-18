-- Bind a successful create key to one client permanently, including after a
-- hard delete. The binding stores a digest and no client fields or contact data.
CREATE TABLE public.crm_client_creation_keys (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  key_digest bytea NOT NULL CHECK (octet_length(key_digest) = 32),
  client_id uuid NOT NULL,
  PRIMARY KEY (organization_id, key_digest)
);
ALTER TABLE public.crm_client_creation_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_client_creation_keys FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.crm_client_creation_keys FROM PUBLIC, anon, authenticated, service_role;

INSERT INTO public.crm_client_creation_keys (organization_id, key_digest, client_id)
SELECT organization_id, extensions.digest(idempotency_key, 'sha256'), id
FROM public.clients WHERE idempotency_key IS NOT NULL;

-- AFTER INSERT covers all existing creators and leaves their successful
-- duplicate-key retry paths intact. A conflicting binding rolls back the insert.
CREATE FUNCTION public.bind_crm_client_creation_key_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  INSERT INTO public.crm_client_creation_keys (organization_id, key_digest, client_id)
  VALUES (NEW.organization_id, extensions.digest(NEW.idempotency_key, 'sha256'), NEW.id)
  ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CRM client create key is already bound' USING ERRCODE = '23505';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.bind_crm_client_creation_key_v1() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER crm_client_creation_key_binding
  AFTER INSERT ON public.clients FOR EACH ROW
  WHEN (NEW.idempotency_key IS NOT NULL)
  EXECUTE FUNCTION public.bind_crm_client_creation_key_v1();
