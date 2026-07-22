import { redirect } from "next/navigation";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { AuditActivityPage, type AuditActivityItem } from "@/features/audit/audit-activity-page";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

async function loadAuditActivity(): Promise<AuditActivityItem[]> {
  try { const client = await createServerSupabaseClient(); const { data: userData } = await client.auth.getUser(); if (!userData.user) redirect("/sign-in"); const { data: memberships } = await client.from("organization_memberships").select("id, organization_id, role, status").eq("user_id", userData.user.id).limit(2); const membership = resolveActiveMembership((memberships ?? []).map((item) => ({ id: item.id, organizationId: item.organization_id, role: item.role, status: item.status }))); if (!membership || membership.role === "viewer") redirect("/access-pending"); const { data, error } = await client.rpc("list_audit_activity", { p_organization_id: membership.organizationId, p_limit: 50 }); if (error) throw error; return ((data ?? []) as { id: string; action: string; resource_type: string; outcome: AuditActivityItem["outcome"]; created_at: string }[]).map((item) => ({ id: item.id, action: item.action, resourceType: item.resource_type, outcome: item.outcome, createdAt: item.created_at })); } catch (error) { if (error instanceof SupabaseConfigurationError) redirect("/sign-in"); throw error; }
}

export default async function AuditActivityWorkspacePage() { return <AuditActivityPage events={await loadAuditActivity()} />; }
