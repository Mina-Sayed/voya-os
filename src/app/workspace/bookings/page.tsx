import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { BookingsPage, type BookingDraftListItem } from "@/features/bookings/bookings-page";
import type { BookingDraftOption } from "@/features/bookings/booking-draft-form";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import {
  cancelBookingDraftAction, completeBookingCommercialSnapshotAction, confirmBookingAction,
  createBookingDraftAction, executeBookingAmendmentAction, executeBookingCancellationAction,
  recordBookingStayEventAction, requestBookingAmendmentAction, requestBookingApprovalAction,
  requestBookingCancellationAction,
} from "./actions";

const bookingRoles = new Set(["owner", "manager", "sales_agent", "operations", "accountant", "viewer"]);

async function loadBookingOptions(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<{ properties: BookingDraftOption[]; clients: BookingDraftOption[]; drafts: BookingDraftListItem[]; currency: string }> {
  const client = await createServerSupabaseClient();
  const [propertiesResult, clientsResult, draftsResult, currencyResult] = await Promise.all([
    client.rpc("list_properties_v1", { p_organization_id: membership.organizationId }),
    client.rpc("list_clients_v1", { p_organization_id: membership.organizationId }),
    client.rpc("list_commercial_booking_work_queue", { p_organization_id: membership.organizationId, p_limit: 50, p_offset: 0 }),
    client.from("organizations").select("default_currency").eq("id", membership.organizationId).maybeSingle(),
  ]);
  if (propertiesResult.error) throwWorkspaceOperationError("workspace.properties.read", propertiesResult.error);
  if (clientsResult.error) throwWorkspaceOperationError("workspace.clients.read", clientsResult.error);
  if (draftsResult.error) throwWorkspaceOperationError("workspace.bookings.read", draftsResult.error);
  if (currencyResult.error) throwWorkspaceOperationError("workspace.organization.read", currencyResult.error);
  type QueueRow = { id: string; property_id: string; property_code: string; property_name: string; client_id: string; client_name: string | null; status: BookingDraftListItem["status"]; check_in: string; check_out: string; agreed_total_amount_minor: string | null; currency: string | null; commercial_completion_status: BookingDraftListItem["commercialCompletionStatus"]; version: number; has_check_in: boolean; has_check_out: boolean; confirmation_approval_status: BookingDraftListItem["confirmationApprovalStatus"]; amendment_approval_status: BookingDraftListItem["amendmentApprovalStatus"]; cancellation_approval_status: BookingDraftListItem["cancellationApprovalStatus"]; created_at: string };
  return {
    properties: ((propertiesResult.data ?? []) as { id: string; code: string; name: string; status: string }[]).filter((item) => item.status === "active").map((item) => ({ id: item.id, label: `${item.code} — ${item.name}` })),
    clients: ((clientsResult.data ?? []) as { id: string; display_name: string; archived_at: string | null }[]).filter((item) => item.archived_at === null).map((item) => ({ id: item.id, label: item.display_name })),
    drafts: ((draftsResult.data ?? []) as QueueRow[]).map((item) => ({ id: item.id, propertyId: item.property_id, propertyLabel: `${item.property_code} — ${item.property_name}`, clientId: item.client_id, clientLabel: item.client_name ?? "عميل غير مرتبط", status: item.status, checkIn: item.check_in, checkOut: item.check_out, amountMinor: item.agreed_total_amount_minor, currency: item.currency, commercialCompletionStatus: item.commercial_completion_status, version: item.version, hasCheckIn: item.has_check_in, hasCheckOut: item.has_check_out, confirmationApprovalStatus: item.confirmation_approval_status, amendmentApprovalStatus: item.amendment_approval_status, cancellationApprovalStatus: item.cancellation_approval_status, createdAt: item.created_at })),
    currency: (currencyResult.data as { default_currency?: string } | null)?.default_currency ?? "EGP",
  };
}

export default async function BookingWorkspacePage() {
  const membership = await requireWorkspaceMembership(bookingRoles); const options = await loadBookingOptions(membership);
  const canRequestChanges = ["owner", "manager", "sales_agent", "operations"].includes(membership.role);
  const canExecuteChanges = membership.role === "owner" || membership.role === "manager";
  return <WorkspaceShell activeHref="/workspace/bookings" organizationName={membership.organizationName} role={membership.role}><BookingsPage actions={{ createDraft: createBookingDraftAction, requestApproval: requestBookingApprovalAction, confirm: confirmBookingAction, cancelDraft: cancelBookingDraftAction, completeSnapshot: completeBookingCommercialSnapshotAction, requestAmendment: requestBookingAmendmentAction, executeAmendment: executeBookingAmendmentAction, requestCancellation: requestBookingCancellationAction, executeCancellation: executeBookingCancellationAction, recordStay: recordBookingStayEventAction }} clients={options.clients} currency={options.currency} drafts={options.drafts} permissions={{ canCreate: canRequestChanges, canRequestChanges, canExecuteChanges, canCompleteSnapshot: canExecuteChanges, canOperateStay: ["owner", "manager", "operations"].includes(membership.role) }} properties={options.properties} /></WorkspaceShell>;
}
