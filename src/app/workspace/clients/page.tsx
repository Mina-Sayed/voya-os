import { redirect } from "next/navigation";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { ClientsPage, type ClientListItem } from "@/features/clients/clients-page";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createClientAction } from "./actions";

async function loadClients(): Promise<ClientListItem[]> {
  try {
    const client = await createServerSupabaseClient();
    const { data: userData } = await client.auth.getUser();
    if (!userData.user) redirect("/sign-in");
    const { data: memberships } = await client.from("organization_memberships").select("id, organization_id, role, status").eq("user_id", userData.user.id).limit(2);
    const membership = resolveActiveMembership((memberships ?? []).map((item) => ({ id: item.id, organizationId: item.organization_id, role: item.role, status: item.status })));
    if (!membership) redirect("/access-pending");
    const { data, error } = await client.rpc("list_clients", { p_organization_id: membership.organizationId });
    if (error) throw error;
    return ((data ?? []) as { id: string; display_name: string; created_at: string }[]).map((item) => ({ id: item.id, displayName: item.display_name, createdAt: item.created_at }));
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) redirect("/sign-in");
    throw error;
  }
}

export default async function ClientsWorkspacePage() { return <ClientsPage clients={await loadClients()} createClient={createClientAction} />; }
