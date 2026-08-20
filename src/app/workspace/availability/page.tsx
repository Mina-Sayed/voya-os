import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { AvailabilityBlocksPage, type AvailabilityBlockListItem } from "@/features/availability/availability-blocks-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import type { AvailabilityPropertyOption } from "@/features/availability/availability-block-create-form";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createAvailabilityBlockAction } from "./actions";

const mutationRoles = new Set(["owner", "manager", "operations"]);

type AvailabilityWorkspaceData = Readonly<{ blocks: AvailabilityBlockListItem[]; properties: AvailabilityPropertyOption[]; canCreate: boolean }>;

async function loadAvailabilityWorkspace(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<AvailabilityWorkspaceData> {
  {
    const client = await createServerSupabaseClient();
    const [propertiesResult, blocksResult] = await Promise.all([client.rpc("list_properties_v1", { p_organization_id: membership.organizationId }), client.rpc("list_availability_blocks", { p_organization_id: membership.organizationId })]);
    if (propertiesResult.error) throwWorkspaceOperationError("workspace.properties.read", propertiesResult.error);
    if (blocksResult.error) throwWorkspaceOperationError("workspace.availability.read", blocksResult.error);
    const properties = ((propertiesResult.data ?? []) as { id: string; code: string; name: string; status: string }[]).filter((item) => item.status === "active").map((item) => ({ id: item.id, label: `${item.code} — ${item.name}` }));
    const propertyLabels = new Map(properties.map((item) => [item.id, item.label]));
    const blocks = ((blocksResult.data ?? []) as { id: string; property_id: string; start_date: string; end_date: string; block_type: AvailabilityBlockListItem["blockType"]; reason: string | null }[]).map((item) => ({ id: item.id, propertyLabel: propertyLabels.get(item.property_id) ?? "عقار غير متاح", startDate: item.start_date, endDate: item.end_date, blockType: item.block_type, reason: item.reason }));
    return { blocks, properties, canCreate: mutationRoles.has(membership.role) };
  }
}

export default async function AvailabilityWorkspacePage() {
  const membership = await requireWorkspaceMembership();
  const workspace = await loadAvailabilityWorkspace(membership);
  return <WorkspaceShell activeHref="/workspace/availability" organizationName={membership.organizationName} role={membership.role}><AvailabilityBlocksPage blocks={workspace.blocks} createBlock={workspace.canCreate ? createAvailabilityBlockAction : undefined} properties={workspace.properties} /></WorkspaceShell>;
}
