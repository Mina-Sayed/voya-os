import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { ApprovalRequestsPage, type ApprovalRequestItem } from "@/features/approvals/approval-requests-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { decideBookingApprovalAction } from "./actions";

async function loadApprovalRequests(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<ApprovalRequestItem[]> {
  const client = await createServerSupabaseClient(); const { data, error } = await client.rpc("list_approval_requests_v2", { p_organization_id: membership.organizationId, p_limit: 50 }); if (error) throwWorkspaceOperationError("workspace.read", error); return ((data ?? []) as { id: string; resource_type: string; resource_id: string; proposed_action: string; status: ApprovalRequestItem["status"]; expires_at: string | null; created_at: string; proposal_summary: ApprovalRequestItem["proposalSummary"]; requester_display_name: string | null }[]).map((item) => ({ id: item.id, resourceId: item.resource_id, resourceType: item.resource_type, proposedAction: item.proposed_action, status: item.status, expiresAt: item.expires_at, createdAt: item.created_at, proposalSummary: item.proposal_summary, requesterDisplayName: item.requester_display_name }));
}
export default async function ApprovalsWorkspacePage() { const membership = await requireWorkspaceMembership(new Set(["owner", "manager", "sales_agent", "operations", "accountant"])); return <WorkspaceShell activeHref="/workspace/approvals" organizationName={membership.organizationName} role={membership.role}><ApprovalRequestsPage canDecide={membership.role === "owner" || membership.role === "manager"} decide={decideBookingApprovalAction} requests={await loadApprovalRequests(membership)} /></WorkspaceShell>; }
