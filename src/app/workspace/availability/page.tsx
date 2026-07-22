import { redirect } from "next/navigation";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { AvailabilityBlocksPage, type AvailabilityBlockListItem } from "@/features/availability/availability-blocks-page";
import type { AvailabilityPropertyOption } from "@/features/availability/availability-block-create-form";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createAvailabilityBlockAction } from "./actions";

const mutationRoles = new Set(["owner", "manager", "operations"]);

type AvailabilityWorkspaceData = Readonly<{ blocks: AvailabilityBlockListItem[]; properties: AvailabilityPropertyOption[]; canCreate: boolean }>;

async function loadAvailabilityWorkspace(): Promise<AvailabilityWorkspaceData> {
  try {
    const client = await createServerSupabaseClient();
    const { data: userData } = await client.auth.getUser();
    if (!userData.user) redirect("/sign-in");
    const { data: memberships } = await client.from("organization_memberships").select("id, organization_id, role, status").eq("user_id", userData.user.id).limit(2);
    const membership = resolveActiveMembership((memberships ?? []).map((item) => ({ id: item.id, organizationId: item.organization_id, role: item.role, status: item.status })));
    if (!membership) redirect("/access-pending");
    const [propertiesResult, blocksResult] = await Promise.all([client.rpc("list_properties", { p_organization_id: membership.organizationId }), client.rpc("list_availability_blocks", { p_organization_id: membership.organizationId })]);
    if (propertiesResult.error) throw propertiesResult.error;
    if (blocksResult.error) throw blocksResult.error;
    const properties = ((propertiesResult.data ?? []) as { id: string; code: string; name: string }[]).map((item) => ({ id: item.id, label: `${item.code} — ${item.name}` }));
    const propertyLabels = new Map(properties.map((item) => [item.id, item.label]));
    const blocks = ((blocksResult.data ?? []) as { id: string; property_id: string; start_date: string; end_date: string; block_type: AvailabilityBlockListItem["blockType"]; reason: string | null }[]).map((item) => ({ id: item.id, propertyLabel: propertyLabels.get(item.property_id) ?? "عقار غير متاح", startDate: item.start_date, endDate: item.end_date, blockType: item.block_type, reason: item.reason }));
    return { blocks, properties, canCreate: mutationRoles.has(membership.role) };
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) redirect("/sign-in");
    throw error;
  }
}

export default async function AvailabilityWorkspacePage() {
  const workspace = await loadAvailabilityWorkspace();
  return <AvailabilityBlocksPage blocks={workspace.blocks} createBlock={workspace.canCreate ? createAvailabilityBlockAction : undefined} properties={workspace.properties} />;
}
