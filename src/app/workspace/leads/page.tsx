import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { LeadsPage, type LeadItem } from "@/features/leads/leads-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createLeadAction } from "./actions";

type LeadRow = { id:string; title:string; source:string; status:string; requested_check_in:string|null; requested_check_out:string|null; created_at:string };
async function loadLeads(member: Awaited<ReturnType<typeof requireWorkspaceMembership>>):Promise<LeadItem[]>{const c=await createServerSupabaseClient();const {data,error}=await c.rpc("list_leads",{p_organization_id:member.organizationId});if(error)throwWorkspaceOperationError("workspace.leads.read",error);return ((data??[]) as LeadRow[]).map((x:LeadRow)=>({id:x.id,title:x.title,source:x.source,status:x.status,requestedCheckIn:x.requested_check_in,requestedCheckOut:x.requested_check_out,createdAt:x.created_at}));}
export default async function LeadsWorkspacePage(){const member=await requireWorkspaceMembership(new Set(["owner","manager","sales_agent"]));return <WorkspaceShell activeHref="/workspace/leads" organizationName={member.organizationName} role={member.role}><LeadsPage leads={await loadLeads(member)} createLead={createLeadAction}/></WorkspaceShell>}
