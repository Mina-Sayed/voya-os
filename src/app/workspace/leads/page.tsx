import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { LeadsPage } from "@/features/leads/leads-page";
import type { LeadActivityItem, LeadFollowUpItem, LeadItem } from "@/features/leads/lead-types";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { readOrganizationTimezone } from "@/lib/organizations/organization-timezone";
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
  ai_unverified: boolean;
}>;

type ActivityRow = Readonly<{ id: string; lead_id: string; actor_membership_id: string; activity_type: string; content: string; created_at: string }>;
type FollowUpRow = Readonly<{ id: string; lead_id: string; assigned_membership_id: string | null; due_at: string; note: string; status: string; completed_at: string | null; completed_by_membership_id: string | null; created_at: string }>;
type LeadDetailSummaryRow = Readonly<{ lead_id: string; activities: ActivityRow[]; follow_ups: FollowUpRow[] }>;
const LEAD_PAGE_SIZE = 50;

async function loadLeads(
  membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>,
  cursor: Readonly<{ createdAt: string; id: string }> | null,
): Promise<Readonly<{ leads: LeadItem[]; nextCursor: string | null }>> {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_leads_v1_page", {
    p_organization_id: membership.organizationId,
    p_after_created_at: cursor?.createdAt ?? null,
    p_after_id: cursor?.id ?? null,
    p_limit: LEAD_PAGE_SIZE + 1,
  });
  if (error) throwWorkspaceOperationError("workspace.leads.read", error);
  const fetchedRows = (data ?? []) as LeadRow[];
  const rows = fetchedRows.slice(0, LEAD_PAGE_SIZE);
  const hasMore = fetchedRows.length > LEAD_PAGE_SIZE;
  let detailRows: LeadDetailSummaryRow[] = [];
  if (rows.length > 0) {
    const detailsResult = await client.rpc("list_lead_page_details_v1", {
      p_organization_id: membership.organizationId,
      p_lead_ids: rows.map((row) => row.id),
    });
    if (detailsResult.error) throwWorkspaceOperationError("workspace.leads.details.read", detailsResult.error);
    detailRows = (detailsResult.data ?? []) as LeadDetailSummaryRow[];
  }
  const detailsByLeadId = new Map(detailRows.map((detail) => [detail.lead_id, detail]));
  const leads = rows.map((row): LeadItem => {
    const detail = detailsByLeadId.get(row.id);
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
      aiUnverified: row.ai_unverified,
      activities: (detail?.activities ?? []).map((activity): LeadActivityItem => ({ id: activity.id, leadId: activity.lead_id, actorMembershipId: activity.actor_membership_id, activityType: activity.activity_type, content: activity.content, createdAt: activity.created_at })),
      followUps: (detail?.follow_ups ?? []).map((followUp): LeadFollowUpItem => ({ id: followUp.id, leadId: followUp.lead_id, assignedMembershipId: followUp.assigned_membership_id, dueAt: followUp.due_at, note: followUp.note, status: followUp.status, completedAt: followUp.completed_at, completedByMembershipId: followUp.completed_by_membership_id, createdAt: followUp.created_at })),
    };
  });
  const lastRow = rows.at(-1);
  return { leads, nextCursor: hasMore && lastRow ? `${lastRow.created_at}|${lastRow.id}` : null };
}

function parseLeadCursor(value: string | string[] | undefined): Readonly<{ createdAt: string; id: string }> | null {
  if (typeof value !== "string" || value.length > 160) return null;
  const separator = value.lastIndexOf("|");
  if (separator < 1) return null;
  const createdAt = value.slice(0, separator);
  const id = value.slice(separator + 1);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/u.test(createdAt)
    || !Number.isFinite(Date.parse(createdAt))
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(id)) return null;
  return { createdAt, id };
}

export default async function LeadsWorkspacePage({
  searchParams,
}: Readonly<{ searchParams: Promise<{ after?: string | string[] }> }>) {
  const query = await searchParams;
  const cursor = parseLeadCursor(query.after);
  const membership = await requireWorkspaceMembership(leadRoles);
  const canCommand = ["owner", "manager", "sales_agent", "operations"].includes(membership.role);
  const client = await createServerSupabaseClient();
  const timezonePromise = readOrganizationTimezone(client, membership.organizationId).catch((error: unknown) => {
    throwWorkspaceOperationError("workspace.organization.read", error);
  });
  const [organizationTimezone, pageData] = await Promise.all([timezonePromise, loadLeads(membership, cursor)]);
  if (!organizationTimezone) throwWorkspaceOperationError("workspace.organization.read", new Error("Organization timezone is unavailable."));
  return <WorkspaceShell activeHref="/workspace/leads" organizationName={membership.organizationName} role={membership.role}><LeadsPage archiveLead={canCommand ? archiveLeadAction : undefined} completeFollowUp={canCommand ? completeLeadFollowUpAction : undefined} convertLead={canCommand ? convertLeadToClientAction : undefined} createActivity={canCommand ? createLeadActivityAction : undefined} createFollowUp={canCommand ? createLeadFollowUpAction : undefined} createLead={canCommand ? createLeadAction : undefined} leads={pageData.leads} nextCursor={pageData.nextCursor} timeZone={organizationTimezone} updateLead={canCommand ? updateLeadAction : undefined} /></WorkspaceShell>;
}
