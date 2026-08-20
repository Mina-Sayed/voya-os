import { createOrganizationId } from "@/domain/tenancy/organization";
import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import type { WorkspaceMembership } from "@/features/auth/workspace-context";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import type { DashboardApproval, DashboardData, DashboardLead, DashboardMetric } from "./dashboard-data";

type PropertyRecord = Readonly<{ id: string; code: string; name: string; timezone: string; status: "active" | "inactive" | "archived"; created_at: string }>;
type ClientRecord = Readonly<{ id: string; display_name: string; archived_at?: string | null; created_at: string }>;
type LeadRecord = Readonly<{ id: string; name?: string | null; title?: string | null; source: string; status: string; requested_check_in: string | null; requested_check_out: string | null; created_at: string }>;
type ApprovalRecord = Readonly<{ id: string; resource_type: string; resource_id: string; proposed_action: string; status: string; expires_at: string | null; created_at: string }>;
type AvailabilityBlockRecord = Readonly<{ id: string; property_id: string; start_date: string; end_date: string; block_type: string; reason: string | null }>;

export type LiveDashboardSource = Readonly<{
  organizationId: string;
  organizationName: string;
  operatorName: string;
  properties: readonly PropertyRecord[];
  clients: readonly ClientRecord[];
  leads: readonly LeadRecord[];
  approvals: readonly ApprovalRecord[];
  availabilityBlocks: readonly AvailabilityBlockRecord[];
}>;

function metric(label: string, value: number, change: string, tone: DashboardMetric["tone"]): DashboardMetric {
  return { label, value: String(value), change, tone };
}

export function buildLiveDashboardData(source: LiveDashboardSource): DashboardData {
  const organizationId = createOrganizationId(source.organizationId);
  const activeProperties = source.properties.filter((property) => property.status === "active").length;
  const pendingApprovals = source.approvals.filter((approval) => approval.status === "pending").length;
  const recentLeads: DashboardLead[] = source.leads.slice(0, 5).map((lead) => ({
    id: lead.id,
    organizationId,
    title: lead.name?.trim() || lead.title?.trim() || "طلب بدون اسم",
    source: lead.source,
    status: lead.status,
    requestedCheckIn: lead.requested_check_in,
    requestedCheckOut: lead.requested_check_out,
    createdAt: lead.created_at,
  }));
  const approvals: DashboardApproval[] = source.approvals.slice(0, 4).map((approval) => ({
    id: approval.id,
    organizationId,
    title: approval.proposed_action,
    detail: `${approval.resource_type} · ${approval.resource_id}`,
    requestedBy: "عضو من المؤسسة",
    requestedAt: new Intl.DateTimeFormat("ar-EG", { day: "numeric", month: "short" }).format(new Date(approval.created_at)),
    urgency: approval.status === "pending" ? "attention" : "normal",
  }));

  return {
    isPreview: false,
    organizationId,
    organizationName: source.organizationName,
    operatorName: source.operatorName,
    dateLabel: new Intl.DateTimeFormat("ar-EG", { weekday: "long", day: "numeric", month: "long" }).format(new Date()),
    metrics: [
      metric("العقارات النشطة", activeProperties, `${source.properties.length} في السجل`, "teal"),
      metric("العملاء", source.clients.length, "سجل المؤسسة", "sand"),
      metric("طلبات المبيعات", source.leads.length, "تحتاج متابعة", "teal"),
      metric("قرارات معلقة", pendingApprovals, `${source.availabilityBlocks.length} حظر توفر`, "coral"),
    ],
    recentLeads,
    approvals,
  };
}

export async function loadLiveDashboardData(existingMembership?: WorkspaceMembership): Promise<DashboardData> {
  const membership = existingMembership ?? await requireWorkspaceMembership();
  const client = await createServerSupabaseClient();
  const canReadClients = new Set(["owner", "manager", "sales_agent", "operations", "accountant", "viewer"]).has(membership.role);
  const canReadLeads = new Set(["owner", "manager", "sales_agent", "operations", "viewer"]).has(membership.role);
  const canReadApprovals = new Set(["owner", "manager", "sales_agent", "operations", "accountant"]).has(membership.role);
  const [propertiesResult, clientsResult, leadsResult, approvalsResult, blocksResult, userResult] = await Promise.all([
    client.rpc("list_properties_v1", { p_organization_id: membership.organizationId }),
    canReadClients ? client.rpc("list_clients_v1", { p_organization_id: membership.organizationId }) : Promise.resolve({ data: [], error: null }),
    canReadLeads ? client.rpc("list_leads_v1", { p_organization_id: membership.organizationId }) : Promise.resolve({ data: [], error: null }),
    canReadApprovals ? client.rpc("list_approval_requests", { p_organization_id: membership.organizationId, p_limit: 50 }) : Promise.resolve({ data: [], error: null }),
    client.rpc("list_availability_blocks", { p_organization_id: membership.organizationId }),
    client.auth.getUser(),
  ]);

  const failures = [propertiesResult, clientsResult, leadsResult, approvalsResult, blocksResult].find((result) => result.error);
  if (failures?.error) throwWorkspaceOperationError("workspace.dashboard.read", failures.error);

  return buildLiveDashboardData({
    organizationId: membership.organizationId,
    organizationName: membership.organizationName,
    operatorName: userResult.data.user?.email?.split("@")[0] ?? "فريق التشغيل",
    properties: (propertiesResult.data ?? []) as PropertyRecord[],
    clients: (clientsResult.data ?? []) as ClientRecord[],
    leads: (leadsResult.data ?? []) as LeadRecord[],
    approvals: (approvalsResult.data ?? []) as ApprovalRecord[],
    availabilityBlocks: (blocksResult.data ?? []) as AvailabilityBlockRecord[],
  });
}
