import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { AuditActivityPage, type AuditActivityItem } from "@/features/audit/audit-activity-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

async function loadAuditActivity(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<AuditActivityItem[]> {
  const client = await createServerSupabaseClient(); const { data, error } = await client.rpc("list_audit_activity", { p_organization_id: membership.organizationId, p_limit: 50 }); if (error) throwWorkspaceOperationError("workspace.read", error); return ((data ?? []) as { id: string; action: string; resource_type: string; outcome: AuditActivityItem["outcome"]; created_at: string }[]).map((item) => ({ id: item.id, action: item.action, resourceType: item.resource_type, outcome: item.outcome, createdAt: item.created_at }));
}

export default async function AuditActivityWorkspacePage() { const membership = await requireWorkspaceMembership(new Set(["owner", "manager", "sales_agent", "operations", "accountant"])); return <WorkspaceShell activeHref="/workspace/activity" organizationName={membership.organizationName} role={membership.role}><AuditActivityPage events={await loadAuditActivity(membership)} /></WorkspaceShell>; }
