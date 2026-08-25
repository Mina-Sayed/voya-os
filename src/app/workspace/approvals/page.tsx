import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { ApprovalRequestsPage, type ApprovalRequestItem } from "@/features/approvals/approval-requests-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { decideBookingApprovalAction } from "./actions";

async function loadApprovalRequests(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<ApprovalRequestItem[]> {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_approval_requests", { p_organization_id: membership.organizationId, p_limit: 50 });
  if (error) throwWorkspaceOperationError("workspace.read", error);
  type Row = { id: string; resource_type: string; resource_id: string; proposed_action: string; status: ApprovalRequestItem["status"]; expires_at: string | null; created_at: string; requester_name: string; current_property_code: string | null; current_property_name: string | null; current_client_name: string | null; current_check_in: string | null; current_check_out: string | null; current_amount_minor: string | null; current_currency: string | null; proposed_property_code: string | null; proposed_property_name: string | null; proposed_client_name: string | null; proposed_check_in: string | null; proposed_check_out: string | null; proposed_amount_minor: string | null; proposed_currency: string | null; reason: string | null };
  return ((data ?? []) as Row[]).map((item) => ({ id: item.id, resourceId: item.resource_id, resourceType: item.resource_type, proposedAction: item.proposed_action, status: item.status, expiresAt: item.expires_at, createdAt: item.created_at, requesterName: item.requester_name, currentPropertyCode: item.current_property_code, currentPropertyName: item.current_property_name, currentClientName: item.current_client_name, currentCheckIn: item.current_check_in, currentCheckOut: item.current_check_out, currentAmountMinor: item.current_amount_minor, currentCurrency: item.current_currency, proposedPropertyCode: item.proposed_property_code, proposedPropertyName: item.proposed_property_name, proposedClientName: item.proposed_client_name, proposedCheckIn: item.proposed_check_in, proposedCheckOut: item.proposed_check_out, proposedAmountMinor: item.proposed_amount_minor, proposedCurrency: item.proposed_currency, reason: item.reason }));
}

export default async function ApprovalsWorkspacePage() {
  const membership = await requireWorkspaceMembership(new Set(["owner", "manager", "sales_agent", "operations", "accountant"]));
  return <WorkspaceShell activeHref="/workspace/approvals" organizationName={membership.organizationName} role={membership.role}><ApprovalRequestsPage canDecide={membership.role === "owner" || membership.role === "manager"} decide={decideBookingApprovalAction} requests={await loadApprovalRequests(membership)} /></WorkspaceShell>;
}
