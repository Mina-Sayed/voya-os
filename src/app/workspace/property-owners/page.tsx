import { redirect } from "next/navigation";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { PropertyOwnersPage, type PropertyOwnerListItem } from "@/features/property-owners/property-owners-page";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createPropertyOwnerAction } from "./actions";

type PropertyOwnerRpcRecord = Readonly<{
  id: string;
  display_name: string;
  status: "active" | "inactive";
  created_at: string;
}>;

async function loadPropertyOwners(): Promise<PropertyOwnerListItem[]> {
  try {
    const client = await createServerSupabaseClient();
    const { data: userData } = await client.auth.getUser();
    if (!userData.user) redirect("/sign-in");

    const { data: memberships } = await client
      .from("organization_memberships")
      .select("id, organization_id, role, status")
      .eq("user_id", userData.user.id)
      .limit(2);
    const membership = resolveActiveMembership((memberships ?? []).map((item) => ({
      id: item.id,
      organizationId: item.organization_id,
      role: item.role,
      status: item.status,
    })));
    if (!membership) redirect("/access-pending");

    const { data, error } = await client.rpc("list_property_owners", {
      p_organization_id: membership.organizationId,
    });
    if (error) throw error;

    return ((data ?? []) as PropertyOwnerRpcRecord[]).map((owner) => ({
      id: owner.id,
      displayName: owner.display_name,
      status: owner.status,
      createdAt: owner.created_at,
    }));
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) redirect("/sign-in");
    throw error;
  }
}

export default async function PropertyOwnersWorkspacePage() {
  const owners = await loadPropertyOwners();
  return <PropertyOwnersPage createOwner={createPropertyOwnerAction} owners={owners} />;
}
