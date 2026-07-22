import { redirect } from "next/navigation";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { PropertiesPage, type PropertyListItem } from "@/features/properties/properties-page";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
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

async function loadProperties(): Promise<PropertyListItem[]> {
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

    const { data, error } = await client.rpc("list_properties", {
      p_organization_id: membership.organizationId,
    });
    if (error) throw error;

    return ((data ?? []) as PropertyRpcRecord[]).map((property) => ({
      id: property.id,
      code: property.code,
      name: property.name,
      timezone: property.timezone,
      status: property.status,
      createdAt: property.created_at,
    }));
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) redirect("/sign-in");
    throw error;
  }
}

export default async function PropertiesWorkspacePage() {
  const properties = await loadProperties();
  return <PropertiesPage createProperty={createPropertyAction} properties={properties} />;
}
