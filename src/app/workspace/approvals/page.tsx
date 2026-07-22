import { redirect } from "next/navigation";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { ApprovalRequestsPage, type ApprovalRequestItem } from "@/features/approvals/approval-requests-page";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

async function loadApprovalRequests(): Promise<ApprovalRequestItem[]> {
  try { const client = await createServerSupabaseClient(); const { data: userData } = await client.auth.getUser(); if (!userData.user) redirect("/sign-in"); const { data: memberships } = await client.from("organization_memberships").select("id, organization_id, role, status").eq("user_id", userData.user.id).limit(2); const membership = resolveActiveMembership((memberships ?? []).map((item) => ({ id: item.id, organizationId: item.organization_id, role: item.role, status: item.status }))); if (!membership || membership.role === "viewer") redirect("/access-pending"); const { data, error } = await client.rpc("list_approval_requests", { p_organization_id: membership.organizationId, p_limit: 50 }); if (error) throw error; return ((data ?? []) as { id: string; resource_type: string; proposed_action: string; status: ApprovalRequestItem["status"]; expires_at: string | null; created_at: string }[]).map((item) => ({ id: item.id, resourceType: item.resource_type, proposedAction: item.proposed_action, status: item.status, expiresAt: item.expires_at, createdAt: item.created_at })); } catch (error) { if (error instanceof SupabaseConfigurationError) redirect("/sign-in"); throw error; }
}
export default async function ApprovalsWorkspacePage() { return <ApprovalRequestsPage requests={await loadApprovalRequests()} />; }
