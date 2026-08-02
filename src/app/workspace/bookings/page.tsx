import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { BookingsPage, type BookingDraftListItem } from "@/features/bookings/bookings-page";
import type { BookingDraftOption } from "@/features/bookings/booking-draft-form";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { confirmBookingAction, createBookingDraftAction, recordBookingStayEventAction, requestBookingApprovalAction } from "./actions";

const bookingRoles = new Set(["owner", "manager", "sales_agent", "operations"]);

async function loadBookingOptions(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<{ properties: BookingDraftOption[]; clients: BookingDraftOption[]; drafts: BookingDraftListItem[] }> {
  {
    const client = await createServerSupabaseClient();
    const [propertiesResult, clientsResult, draftsResult] = await Promise.all([
      client.rpc("list_properties", { p_organization_id: membership.organizationId }),
      client.rpc("list_clients", { p_organization_id: membership.organizationId }),
      client.rpc("list_booking_work_queue", { p_organization_id: membership.organizationId }),
    ]);
    if (propertiesResult.error) throwWorkspaceOperationError("workspace.properties.read", propertiesResult.error);
    if (clientsResult.error) throwWorkspaceOperationError("workspace.clients.read", clientsResult.error);
    if (draftsResult.error) throwWorkspaceOperationError("workspace.bookings.read", draftsResult.error);
    return {
      properties: ((propertiesResult.data ?? []) as { id: string; code: string; name: string }[]).map((item) => ({ id: item.id, label: `${item.code} — ${item.name}` })),
      clients: ((clientsResult.data ?? []) as { id: string; display_name: string }[]).map((item) => ({ id: item.id, label: item.display_name })),
      drafts: ((draftsResult.data ?? []) as { id: string; property_code: string; property_name: string; client_name: string | null; status: BookingDraftListItem["status"]; check_in: string; check_out: string; has_check_in: boolean; has_check_out: boolean; created_at: string }[]).map((item) => ({ id: item.id, propertyLabel: `${item.property_code} — ${item.property_name}`, clientLabel: item.client_name ?? "عميل غير مرتبط", status: item.status, checkIn: item.check_in, checkOut: item.check_out, hasCheckIn: item.has_check_in, hasCheckOut: item.has_check_out, createdAt: item.created_at })),
    };
  }
}

export default async function BookingWorkspacePage() { const membership = await requireWorkspaceMembership(bookingRoles); const options = await loadBookingOptions(membership); return <WorkspaceShell activeHref="/workspace/bookings" organizationName={membership.organizationName} role={membership.role}><BookingsPage canOperateStay={membership.role === "owner" || membership.role === "manager" || membership.role === "operations"} confirmBooking={confirmBookingAction} createDraft={createBookingDraftAction} properties={options.properties} clients={options.clients} drafts={options.drafts} recordStay={recordBookingStayEventAction} requestApproval={requestBookingApprovalAction} /></WorkspaceShell>; }
