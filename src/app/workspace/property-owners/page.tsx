import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { PropertyOwnersPage, type PropertyOwnerListItem } from "@/features/property-owners/property-owners-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { archivePropertyOwnerAction, createPropertyOwnerAction, restorePropertyOwnerAction, updatePropertyOwnerAction } from "./actions";

type PropertyOwnerRpcRecord = Readonly<{
  id: string;
  display_name: string;
  phone: string | null;
  whatsapp: string | null;
  email: string | null;
  preferred_contact_method: string | null;
  notes: string | null;
  status: "active" | "inactive" | "archived";
  version: number;
  created_at: string;
  archived_at: string | null;
}>;

async function loadPropertyOwners(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<PropertyOwnerListItem[]> {
  {
    const client = await createServerSupabaseClient();
    const { data, error } = await client.rpc("list_property_owners_v1", {
      p_organization_id: membership.organizationId,
    });
    if (error) throwWorkspaceOperationError("workspace.read", error);

    return ((data ?? []) as PropertyOwnerRpcRecord[]).map((owner) => ({
      id: owner.id,
      displayName: owner.display_name,
      phone: owner.phone,
      whatsapp: owner.whatsapp,
      email: owner.email,
      preferredContactMethod: owner.preferred_contact_method,
      notes: owner.notes,
      status: owner.status,
      version: owner.version,
      createdAt: owner.created_at,
      archivedAt: owner.archived_at,
    }));
  }
}

export default async function PropertyOwnersWorkspacePage() {
  const membership = await requireWorkspaceMembership();
  const owners = await loadPropertyOwners(membership);
  const canManage = ["owner", "manager", "operations"].includes(membership.role);
  return <WorkspaceShell activeHref="/workspace/property-owners" organizationName={membership.organizationName} role={membership.role}><PropertyOwnersPage archiveOwner={canManage ? archivePropertyOwnerAction : undefined} canManage={canManage} createOwner={canManage ? createPropertyOwnerAction : undefined} owners={owners} restoreOwner={canManage ? restorePropertyOwnerAction : undefined} updateOwner={canManage ? updatePropertyOwnerAction : undefined} /></WorkspaceShell>;
}
