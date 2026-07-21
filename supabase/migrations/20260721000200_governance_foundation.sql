-- Voya OS: append-only audit and generic approval record foundation.
-- This migration creates facts only; command execution and policy thresholds remain application concerns.

ALTER TABLE public.organization_memberships
  ADD CONSTRAINT organization_memberships_organization_id_id_unique UNIQUE (organization_id, id);

CREATE TABLE public.approval_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  resource_type text NOT NULL CHECK (char_length(btrim(resource_type)) > 0),
  resource_id uuid NOT NULL,
  proposed_action text NOT NULL CHECK (proposed_action ~ '^[a-z][a-z0-9_]*([.][a-z][a-z0-9_]*)+$'),
  proposal_snapshot jsonb NOT NULL,
  snapshot_hash text NOT NULL CHECK (snapshot_hash ~ '^[a-f0-9]{64}$'),
  requester_membership_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'expired', 'cancelled', 'executed')),
  expires_at timestamptz,
  executed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT approval_requester_in_organization_fk
    FOREIGN KEY (organization_id, requester_membership_id)
    REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT approval_request_executed_state_check
    CHECK ((status = 'executed') = (executed_at IS NOT NULL)),
  UNIQUE (organization_id, id)
);

CREATE TABLE public.approval_decisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  approval_request_id uuid NOT NULL,
  approver_membership_id uuid NOT NULL,
  decision text NOT NULL CHECK (decision IN ('approved', 'rejected')),
  reason text NOT NULL CHECK (char_length(btrim(reason)) > 0),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT approval_decision_request_in_organization_fk
    FOREIGN KEY (organization_id, approval_request_id)
    REFERENCES public.approval_requests (organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT approval_decision_approver_in_organization_fk
    FOREIGN KEY (organization_id, approver_membership_id)
    REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT,
  UNIQUE (approval_request_id, approver_membership_id)
);

CREATE TABLE public.audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE RESTRICT,
  actor_type text NOT NULL CHECK (actor_type IN ('user', 'ai_on_behalf_of_user', 'system', 'support')),
  actor_membership_id uuid,
  action text NOT NULL CHECK (char_length(btrim(action)) > 0),
  resource_type text NOT NULL CHECK (char_length(btrim(resource_type)) > 0),
  resource_id uuid NOT NULL,
  outcome text NOT NULL CHECK (outcome IN ('success', 'denied', 'error')),
  request_id uuid,
  reason_code text,
  before_delta jsonb,
  after_delta jsonb,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT audit_actor_in_organization_fk
    FOREIGN KEY (organization_id, actor_membership_id)
    REFERENCES public.organization_memberships (organization_id, id) ON DELETE RESTRICT,
  UNIQUE (organization_id, id)
);

CREATE INDEX approval_requests_pending_idx
  ON public.approval_requests (organization_id, created_at DESC)
  WHERE status = 'pending';
CREATE INDEX audit_events_organization_resource_idx
  ON public.audit_events (organization_id, resource_type, resource_id, created_at DESC);
CREATE INDEX audit_events_organization_created_at_idx
  ON public.audit_events (organization_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.reject_immutable_record()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION 'immutable records cannot be modified or deleted' USING ERRCODE = '23514';
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_self_approval()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  requester_id uuid;
BEGIN
  SELECT requester_membership_id INTO requester_id
  FROM public.approval_requests
  WHERE id = NEW.approval_request_id AND organization_id = NEW.organization_id;

  IF requester_id = NEW.approver_membership_id THEN
    RAISE EXCEPTION 'requester cannot approve their own request' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER approval_decisions_immutable
  BEFORE UPDATE OR DELETE ON public.approval_decisions
  FOR EACH ROW EXECUTE FUNCTION public.reject_immutable_record();
CREATE TRIGGER audit_events_immutable
  BEFORE UPDATE OR DELETE ON public.audit_events
  FOR EACH ROW EXECUTE FUNCTION public.reject_immutable_record();
CREATE TRIGGER approval_decisions_no_self_approval
  BEFORE INSERT ON public.approval_decisions
  FOR EACH ROW EXECUTE FUNCTION public.reject_self_approval();
CREATE TRIGGER approval_requests_set_updated_at
  BEFORE UPDATE ON public.approval_requests
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.approval_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approval_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approval_requests FORCE ROW LEVEL SECURITY;
ALTER TABLE public.approval_decisions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.audit_events FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.approval_requests, public.approval_decisions, public.audit_events FROM PUBLIC;
