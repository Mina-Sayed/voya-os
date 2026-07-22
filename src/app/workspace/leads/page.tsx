import { redirect } from "next/navigation";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { LeadsPage, type LeadItem } from "@/features/leads/leads-page";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createLeadAction } from "./actions";

type LeadRow = { id:string; title:string; source:string; status:string; requested_check_in:string|null; requested_check_out:string|null; created_at:string };
async function loadLeads():Promise<LeadItem[]>{try{const c=await createServerSupabaseClient(),{data:{user}}=await c.auth.getUser();if(!user)redirect("/sign-in");const {data:m}=await c.from("organization_memberships").select("id, organization_id, role, status").eq("user_id",user.id).limit(2),member=resolveActiveMembership((m??[]).map(x=>({id:x.id,organizationId:x.organization_id,role:x.role,status:x.status})));if(!member||!["owner","manager","sales_agent"].includes(member.role))redirect("/access-pending");const {data,error}=await c.rpc("list_leads",{p_organization_id:member.organizationId});if(error)throw error;return ((data??[]) as LeadRow[]).map((x:LeadRow)=>({id:x.id,title:x.title,source:x.source,status:x.status,requestedCheckIn:x.requested_check_in,requestedCheckOut:x.requested_check_out,createdAt:x.created_at}));}catch(error){if(error instanceof SupabaseConfigurationError)redirect("/sign-in");throw error}}
export default async function LeadsWorkspacePage(){return <LeadsPage leads={await loadLeads()} createLead={createLeadAction}/>}
