import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { AuditActivityPage, type AuditActivityFilters, type AuditActivityItem, type AuditMemberOption } from "@/features/audit/audit-activity-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

type SearchParams = Readonly<Record<string, string | string[] | undefined>>;

type AuditRow = Readonly<{
  id: string;
  action: string;
  resource_type: string;
  resource_id: string | null;
  actor_type: string;
  actor_membership_id: string | null;
  actor_display_name: string;
  outcome: AuditActivityItem["outcome"];
  reason_code: string | null;
  before_delta: Record<string, unknown> | null;
  after_delta: Record<string, unknown> | null;
  created_at: string;
}>;

type MemberRow = Readonly<{ id: string; display_name: string; role: string; status: string }>;

function firstParam(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] ?? "" : value ?? "";
}

function validDate(value: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return "";
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value ? "" : value;
}

function validUuid(value: string) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value) ? value : "";
}

function validFilter(value: string, maxLength: number) {
  return value.trim().slice(0, maxLength);
}

function toStartOfDay(value: string) {
  return value ? `${value}T00:00:00.000Z` : null;
}

function toEndOfDay(value: string) {
  return value ? `${value}T23:59:59.999Z` : null;
}

function parseFilters(searchParams: SearchParams): AuditActivityFilters {
  const from = validDate(firstParam(searchParams.from));
  const to = validDate(firstParam(searchParams.to));
  const reverseRange = from !== "" && to !== "" && from > to;
  return {
    from: reverseRange ? to : from,
    to: reverseRange ? from : to,
    actorMembershipId: validUuid(validFilter(firstParam(searchParams.member), 80)),
    action: validFilter(firstParam(searchParams.action), 160),
    resourceType: validFilter(firstParam(searchParams.resource), 120),
  };
}

async function loadAuditActivity(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>, filters: AuditActivityFilters) {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_audit_activity_filtered", {
    p_organization_id: membership.organizationId,
    p_limit: 100,
    p_from: toStartOfDay(filters.from),
    p_to: toEndOfDay(filters.to),
    p_actor_membership_id: filters.actorMembershipId || null,
    p_action: filters.action || null,
    p_resource_type: filters.resourceType || null,
  });
  if (error) throwWorkspaceOperationError("workspace.read", error);
  return ((data ?? []) as AuditRow[]).map((item) => ({
    id: item.id,
    action: item.action,
    resourceType: item.resource_type,
    resourceId: item.resource_id,
    actorType: item.actor_type,
    actorMembershipId: item.actor_membership_id,
    actorDisplayName: item.actor_display_name,
    outcome: item.outcome,
    reasonCode: item.reason_code,
    beforeDelta: item.before_delta,
    afterDelta: item.after_delta,
    createdAt: item.created_at,
  })) satisfies AuditActivityItem[];
}

async function loadAuditMembers(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>) {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_organization_members", { p_organization_id: membership.organizationId });
  if (error) throwWorkspaceOperationError("workspace.members.read", error);
  return ((data ?? []) as MemberRow[]).map((member) => ({ id: member.id, displayName: member.display_name, role: member.role, status: member.status })) satisfies AuditMemberOption[];
}

export default async function AuditActivityWorkspacePage({ searchParams }: Readonly<{ searchParams: Promise<SearchParams> }>) {
  const membership = await requireWorkspaceMembership(new Set(["owner", "manager", "sales_agent", "operations", "accountant"]));
  const filters = parseFilters(await searchParams);
  const [events, members] = await Promise.all([loadAuditActivity(membership, filters), loadAuditMembers(membership)]);
  return <WorkspaceShell activeHref="/workspace/activity" organizationName={membership.organizationName} role={membership.role}><AuditActivityPage events={events} filters={filters} members={members} /></WorkspaceShell>;
}
