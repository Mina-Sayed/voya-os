import { redirect } from "next/navigation";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { BookingDraftForm, type BookingDraftOption } from "@/features/bookings/booking-draft-form";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createBookingDraftAction } from "./actions";

const bookingRoles = new Set(["owner", "manager", "sales_agent", "operations"]);

async function loadBookingOptions(): Promise<{ properties: BookingDraftOption[]; clients: BookingDraftOption[] }> {
  try {
    const client = await createServerSupabaseClient(); const { data: userData } = await client.auth.getUser();
    if (!userData.user) redirect("/sign-in");
    const { data: memberships } = await client.from("organization_memberships").select("id, organization_id, role, status").eq("user_id", userData.user.id).limit(2);
    const membership = resolveActiveMembership((memberships ?? []).map((item) => ({ id: item.id, organizationId: item.organization_id, role: item.role, status: item.status })));
    if (!membership || !bookingRoles.has(membership.role)) redirect("/access-pending");
    const [propertiesResult, clientsResult] = await Promise.all([
      client.rpc("list_properties", { p_organization_id: membership.organizationId }),
      client.rpc("list_clients", { p_organization_id: membership.organizationId }),
    ]);
    if (propertiesResult.error) throw propertiesResult.error;
    if (clientsResult.error) throw clientsResult.error;
    return {
      properties: ((propertiesResult.data ?? []) as { id: string; code: string; name: string }[]).map((item) => ({ id: item.id, label: `${item.code} — ${item.name}` })),
      clients: ((clientsResult.data ?? []) as { id: string; display_name: string }[]).map((item) => ({ id: item.id, label: item.display_name })),
    };
  } catch (error) { if (error instanceof SupabaseConfigurationError) redirect("/sign-in"); throw error; }
}

export default async function BookingWorkspacePage() { const options = await loadBookingOptions(); return <BookingDraftForm createDraft={createBookingDraftAction} properties={options.properties} clients={options.clients} />; }
