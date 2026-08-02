import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { ClientsPage, type ClientListItem } from "@/features/clients/clients-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createClientAction } from "./actions";

async function loadClients(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<ClientListItem[]> {
  {
    const client = await createServerSupabaseClient();
    const { data, error } = await client.rpc("list_clients", { p_organization_id: membership.organizationId });
    if (error) throwWorkspaceOperationError("workspace.read", error);
    return ((data ?? []) as { id: string; display_name: string; created_at: string }[]).map((item) => ({ id: item.id, displayName: item.display_name, createdAt: item.created_at }));
  }
}

export default async function ClientsWorkspacePage() { const membership = await requireWorkspaceMembership(); return <WorkspaceShell activeHref="/workspace/clients" organizationName={membership.organizationName} role={membership.role}><ClientsPage clients={await loadClients(membership)} createClient={createClientAction} /></WorkspaceShell>; }
