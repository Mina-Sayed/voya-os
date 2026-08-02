import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { PropertyOwnersPage, type PropertyOwnerListItem } from "@/features/property-owners/property-owners-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createPropertyOwnerAction } from "./actions";

type PropertyOwnerRpcRecord = Readonly<{
  id: string;
  display_name: string;
  status: "active" | "inactive";
  created_at: string;
}>;

async function loadPropertyOwners(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<PropertyOwnerListItem[]> {
  {
    const client = await createServerSupabaseClient();
    const { data, error } = await client.rpc("list_property_owners", {
      p_organization_id: membership.organizationId,
    });
    if (error) throwWorkspaceOperationError("workspace.read", error);

    return ((data ?? []) as PropertyOwnerRpcRecord[]).map((owner) => ({
      id: owner.id,
      displayName: owner.display_name,
      status: owner.status,
      createdAt: owner.created_at,
    }));
  }
}

export default async function PropertyOwnersWorkspacePage() {
  const membership = await requireWorkspaceMembership();
  const owners = await loadPropertyOwners(membership);
  return <WorkspaceShell activeHref="/workspace/property-owners" organizationName={membership.organizationName} role={membership.role}><PropertyOwnersPage createOwner={createPropertyOwnerAction} owners={owners} /></WorkspaceShell>;
}
