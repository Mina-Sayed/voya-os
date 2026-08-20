import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { ClientsPage } from "@/features/clients/clients-page";
import type { ClientListItem } from "@/features/clients/client-types";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { archiveClientAction, createClientAction, updateClientAction } from "./actions";

const clientRoles = new Set(["owner", "manager", "sales_agent", "operations", "accountant", "viewer"]);
const commandRoles = new Set(["owner", "manager", "sales_agent", "operations"]);

type ClientRow = Readonly<{ id: string; display_name: string; phone: string | null; whatsapp: string | null; email: string | null; nationality: string | null; preferred_language: string | null; notes: string | null; source_lead_id: string | null; version: number; created_at: string; updated_at: string; archived_at: string | null; duplicate_warning: boolean }>;

async function loadClients(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<ClientListItem[]> {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_clients_v1", { p_organization_id: membership.organizationId });
  if (error) throwWorkspaceOperationError("workspace.clients.read", error);
  return ((data ?? []) as ClientRow[]).map((item): ClientListItem => ({ id: item.id, displayName: item.display_name, phone: item.phone, whatsapp: item.whatsapp, email: item.email, nationality: item.nationality, preferredLanguage: item.preferred_language, notes: item.notes, sourceLeadId: item.source_lead_id, version: item.version, createdAt: item.created_at, updatedAt: item.updated_at, archivedAt: item.archived_at, duplicateWarning: item.duplicate_warning }));
}
export default async function ClientsWorkspacePage() {
  const membership = await requireWorkspaceMembership(clientRoles);
  const canCommand = commandRoles.has(membership.role);
  return <WorkspaceShell activeHref="/workspace/clients" organizationName={membership.organizationName} role={membership.role}><ClientsPage archiveClient={canCommand ? archiveClientAction : undefined} clients={await loadClients(membership)} createClient={canCommand ? createClientAction : undefined} updateClient={canCommand ? updateClientAction : undefined} /></WorkspaceShell>;
}
