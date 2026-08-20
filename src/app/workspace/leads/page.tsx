import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { LeadsPage } from "@/features/leads/leads-page";
import type { LeadActivityItem, LeadFollowUpItem, LeadItem } from "@/features/leads/lead-types";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { archiveLeadAction, completeLeadFollowUpAction, convertLeadToClientAction, createLeadAction, createLeadActivityAction, createLeadFollowUpAction, updateLeadAction } from "./actions";

const leadRoles = new Set(["owner", "manager", "sales_agent", "operations", "viewer"]);

type LeadRow = Readonly<{
  id: string;
  name: string | null;
  phone: string | null;
  whatsapp: string | null;
  email: string | null;
  source: string;
  status: string;
  assigned_membership_id: string | null;
  requested_area: string | null;
  requested_check_in: string | null;
  requested_check_out: string | null;
  guests: number | null;
  bedrooms: number | null;
  budget_text: string | null;
  notes: string | null;
  next_follow_up_at: string | null;
  version: number;
  converted_client_id: string | null;
  created_at: string;
  updated_at: string;
  archived_at: string | null;
  duplicate_warning: boolean;
}>;

type ActivityRow = Readonly<{ id: string; lead_id: string; actor_membership_id: string; activity_type: string; content: string; created_at: string }>;
type FollowUpRow = Readonly<{ id: string; lead_id: string; assigned_membership_id: string | null; due_at: string; note: string; status: string; completed_at: string | null; completed_by_membership_id: string | null; created_at: string }>;

async function loadLeads(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<LeadItem[]> {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_leads_v1", { p_organization_id: membership.organizationId });
  if (error) throwWorkspaceOperationError("workspace.leads.read", error);
  const rows = (data ?? []) as LeadRow[];
  return Promise.all(rows.map(async (row): Promise<LeadItem> => {
    const [activitiesResult, followUpsResult] = await Promise.all([
      client.rpc("list_lead_activities_v1", { p_organization_id: membership.organizationId, p_lead_id: row.id }),
      client.rpc("list_lead_follow_ups_v1", { p_organization_id: membership.organizationId, p_lead_id: row.id }),
    ]);
    if (activitiesResult.error) throwWorkspaceOperationError("workspace.leads.activities.read", activitiesResult.error);
    if (followUpsResult.error) throwWorkspaceOperationError("workspace.leads.follow_ups.read", followUpsResult.error);
    return {
      id: row.id,
      name: row.name,
      phone: row.phone,
      whatsapp: row.whatsapp,
      email: row.email,
      source: row.source,
      status: row.status,
      assignedMembershipId: row.assigned_membership_id,
      requestedArea: row.requested_area,
      requestedCheckIn: row.requested_check_in,
      requestedCheckOut: row.requested_check_out,
      guests: row.guests,
      bedrooms: row.bedrooms,
      budgetText: row.budget_text,
      notes: row.notes,
      nextFollowUpAt: row.next_follow_up_at,
      version: row.version,
      convertedClientId: row.converted_client_id,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      archivedAt: row.archived_at,
      duplicateWarning: row.duplicate_warning,
      activities: ((activitiesResult.data ?? []) as ActivityRow[]).map((activity): LeadActivityItem => ({ id: activity.id, leadId: activity.lead_id, actorMembershipId: activity.actor_membership_id, activityType: activity.activity_type, content: activity.content, createdAt: activity.created_at })),
      followUps: ((followUpsResult.data ?? []) as FollowUpRow[]).map((followUp): LeadFollowUpItem => ({ id: followUp.id, leadId: followUp.lead_id, assignedMembershipId: followUp.assigned_membership_id, dueAt: followUp.due_at, note: followUp.note, status: followUp.status, completedAt: followUp.completed_at, completedByMembershipId: followUp.completed_by_membership_id, createdAt: followUp.created_at })),
    };
  }));
}
export default async function LeadsWorkspacePage() {
  const membership = await requireWorkspaceMembership(leadRoles);
  const canCommand = ["owner", "manager", "sales_agent", "operations"].includes(membership.role);
  return <WorkspaceShell activeHref="/workspace/leads" organizationName={membership.organizationName} role={membership.role}><LeadsPage archiveLead={canCommand ? archiveLeadAction : undefined} completeFollowUp={canCommand ? completeLeadFollowUpAction : undefined} convertLead={canCommand ? convertLeadToClientAction : undefined} createActivity={canCommand ? createLeadActivityAction : undefined} createFollowUp={canCommand ? createLeadFollowUpAction : undefined} createLead={canCommand ? createLeadAction : undefined} leads={await loadLeads(membership)} updateLead={canCommand ? updateLeadAction : undefined} /></WorkspaceShell>;
}
