import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { PropertiesPage, type PropertyListItem } from "@/features/properties/properties-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createPropertyAction } from "./actions";

type PropertyRpcRecord = Readonly<{
  id: string;
  code: string;
  name: string;
  timezone: string;
  status: "active" | "inactive";
  created_at: string;
}>;

async function loadProperties(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<PropertyListItem[]> {
  {
    const client = await createServerSupabaseClient();
    const { data, error } = await client.rpc("list_properties", {
      p_organization_id: membership.organizationId,
    });
    if (error) throwWorkspaceOperationError("workspace.read", error);

    return ((data ?? []) as PropertyRpcRecord[]).map((property) => ({
      id: property.id,
      code: property.code,
      name: property.name,
      timezone: property.timezone,
      status: property.status,
      createdAt: property.created_at,
    }));
  }
}

export default async function PropertiesWorkspacePage() {
  const membership = await requireWorkspaceMembership();
  const properties = await loadProperties(membership);
  return <WorkspaceShell activeHref="/workspace/properties" organizationName={membership.organizationName} role={membership.role}><PropertiesPage createProperty={createPropertyAction} properties={properties} /></WorkspaceShell>;
}
