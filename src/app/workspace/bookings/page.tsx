import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { BookingsPage, type BookingDraftListItem } from "@/features/bookings/bookings-page";
import type { BookingDraftOption } from "@/features/bookings/booking-draft-form";
import { indexExecutableBookingChanges } from "@/features/bookings/executable-amendments";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import {
  confirmBookingAction,
  createBookingDraftAction,
  executeBookingAmendmentAction,
  recordBookingStayEventAction,
  requestBookingAmendmentAction,
  requestBookingApprovalAction,
} from "./actions";

const bookingRoles = new Set(["owner", "manager", "sales_agent", "operations", "viewer"]);

async function loadBookingOptions(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<{ properties: BookingDraftOption[]; clients: BookingDraftOption[]; drafts: BookingDraftListItem[]; currency: string }> {
  const client = await createServerSupabaseClient();
  const [propertiesResult, clientsResult, draftsResult, currencyResult] = await Promise.all([
    client.rpc("list_properties_v1", { p_organization_id: membership.organizationId }),
    client.rpc("list_clients_v1", { p_organization_id: membership.organizationId }),
    client.rpc("list_commercial_booking_work_queue", { p_organization_id: membership.organizationId }),
    client.from("organizations").select("default_currency").eq("id", membership.organizationId).maybeSingle(),
  ]);
  if (propertiesResult.error) throwWorkspaceOperationError("workspace.properties.read", propertiesResult.error);
  if (clientsResult.error) throwWorkspaceOperationError("workspace.clients.read", clientsResult.error);
  if (draftsResult.error) throwWorkspaceOperationError("workspace.bookings.read", draftsResult.error);
  if (currencyResult.error) throwWorkspaceOperationError("workspace.organization.read", currencyResult.error);

  const draftRows = (draftsResult.data ?? []) as { id: string; property_code: string; property_name: string; client_name: string | null; status: BookingDraftListItem["status"]; check_in: string; check_out: string; agreed_total_amount_minor: string | null; currency: string | null; commercial_completion_status: BookingDraftListItem["commercialCompletionStatus"]; version: number; has_check_in: boolean; has_check_out: boolean; created_at: string }[];
  const bookingIds = draftRows.map((item) => item.id);
  const executableChangesResult = membership.role === "owner" || membership.role === "manager"
    ? bookingIds.length > 0
      ? await client.rpc("list_executable_booking_changes_v1", { p_organization_id: membership.organizationId, p_booking_ids: bookingIds })
      : { data: [], error: null }
    : { data: [], error: null };
  if (executableChangesResult.error) throwWorkspaceOperationError("workspace.approvals.executable.read", executableChangesResult.error);

  const executableChanges = indexExecutableBookingChanges(
    (executableChangesResult.data ?? []) as { booking_id: string; approval_request_id: string; proposed_action: "booking.confirm" | "booking.amend" }[],
  );
  return {
    properties: ((propertiesResult.data ?? []) as { id: string; code: string; name: string; status: string }[]).filter((item) => item.status === "active").map((item) => ({ id: item.id, label: `${item.code} — ${item.name}` })),
    clients: ((clientsResult.data ?? []) as { id: string; display_name: string; archived_at: string | null }[]).filter((item) => item.archived_at === null).map((item) => ({ id: item.id, label: item.display_name })),
    drafts: draftRows.map((item) => ({ id: item.id, propertyLabel: `${item.property_code} — ${item.property_name}`, clientLabel: item.client_name ?? "عميل غير مرتبط", status: item.status, checkIn: item.check_in, checkOut: item.check_out, amountMinor: item.agreed_total_amount_minor, currency: item.currency, commercialCompletionStatus: item.commercial_completion_status, version: item.version, hasCheckIn: item.has_check_in, hasCheckOut: item.has_check_out, createdAt: item.created_at, hasExecutableConfirmation: executableChanges.confirmationBookingIds.has(item.id), latestApprovedAmendmentId: executableChanges.amendmentByBooking.get(item.id) ?? null })),
    currency: (currencyResult.data as { default_currency?: string } | null)?.default_currency ?? "EGP",
  };
}

export default async function BookingWorkspacePage() {
  const membership = await requireWorkspaceMembership(bookingRoles);
  const options = await loadBookingOptions(membership);
  return <WorkspaceShell activeHref="/workspace/bookings" organizationName={membership.organizationName} role={membership.role}>
    <BookingsPage
      canApprove={membership.role === "owner" || membership.role === "manager"}
      canOperateStay={membership.role === "owner" || membership.role === "manager" || membership.role === "operations"}
      canRequestAmendment={membership.role === "owner" || membership.role === "manager" || membership.role === "sales_agent" || membership.role === "operations"}
      clients={options.clients}
      confirmBooking={confirmBookingAction}
      createDraft={createBookingDraftAction}
      currency={options.currency}
      drafts={options.drafts}
      executeAmendment={executeBookingAmendmentAction}
      properties={options.properties}
      recordStay={recordBookingStayEventAction}
      requestAmendment={requestBookingAmendmentAction}
      requestApproval={requestBookingApprovalAction}
    />
  </WorkspaceShell>;
}
