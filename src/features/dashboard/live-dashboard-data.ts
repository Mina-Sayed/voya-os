import type { SupabaseClient } from "@supabase/supabase-js";
import { createOrganizationId, type OrganizationId } from "@/domain/tenancy/organization";
import type { WorkspaceMembership } from "@/features/auth/workspace-context";
import type { DashboardApproval, DashboardBooking, DashboardData } from "./dashboard-data";

export type LiveBookingRow = Readonly<{
  id: string;
  propertyCode: string;
  propertyName: string;
  clientName: string | null;
  status: string;
  checkIn: string;
  checkOut: string;
  hasCheckIn: boolean;
  hasCheckOut: boolean;
  createdAt: string;
}>;

export type LiveApprovalRow = Readonly<{
  id: string;
  resourceType: string;
  resourceId: string;
  proposedAction: string;
  status: string;
  expiresAt: string | null;
  createdAt: string;
}>;

export type LiveDashboardInputs = Readonly<{
  organizationId: OrganizationId;
  organizationName: string;
  operatorName: string;
  today: string;
  activePropertyCount: number;
  bookings: readonly LiveBookingRow[];
  approvals: readonly LiveApprovalRow[];
}>;

type BookingRpcRow = Readonly<{
  id: string;
  property_code: string;
  property_name: string;
  client_name: string | null;
  status: string;
  check_in: string;
  check_out: string;
  has_check_in: boolean;
  has_check_out: boolean;
  created_at: string;
}>;

type PropertyRpcRow = Readonly<{ id: string; status: string }>;

type ApprovalRpcRow = Readonly<{
  id: string;
  resource_type: string;
  resource_id: string;
  proposed_action: string;
  status: string;
  expires_at: string | null;
  created_at: string;
}>;

type DashboardRpcClient = Pick<SupabaseClient, "rpc">;

const activeBookingStatuses = new Set(["confirmed", "pending_approval"]);

function dateAtUtcMidnight(date: string): Date {
  return new Date(`${date}T00:00:00.000Z`);
}

function dateKey(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function addDays(date: string, amount: number): string {
  const result = dateAtUtcMidnight(date);
  result.setUTCDate(result.getUTCDate() + amount);
  return dateKey(result);
}

function dateDistance(start: string, end: string): number {
  return Math.max(0, Math.round((dateAtUtcMidnight(end).getTime() - dateAtUtcMidnight(start).getTime()) / 86_400_000));
}

function overlapNights(start: string, end: string, windowStart: string, windowEnd: string): number {
  const overlapStart = start > windowStart ? start : windowStart;
  const overlapEnd = end < windowEnd ? end : windowEnd;
  return overlapStart < overlapEnd ? dateDistance(overlapStart, overlapEnd) : 0;
}

function liveBookingRows(bookings: readonly LiveBookingRow[], today: string): LiveBookingRow[] {
  return bookings
    .filter((booking) => activeBookingStatuses.has(booking.status) && booking.checkOut > today)
    .sort((left, right) => left.checkIn.localeCompare(right.checkIn) || right.createdAt.localeCompare(left.createdAt))
    .slice(0, 6);
}

function formatDateLabel(date: string): string {
  return new Intl.DateTimeFormat("ar-EG", { day: "numeric", month: "short" }).format(dateAtUtcMidnight(date));
}

function formatWeekday(date: string): string {
  return new Intl.DateTimeFormat("ar-EG", { weekday: "long" }).format(dateAtUtcMidnight(date));
}

function formatDateRangeLabel(today: string): string {
  const formatter = new Intl.DateTimeFormat("en-US", { day: "numeric", month: "short" });
  return `${formatter.format(dateAtUtcMidnight(today)).toUpperCase()} — ${formatter.format(dateAtUtcMidnight(addDays(today, 6))).toUpperCase()}`;
}

function stayLabel(checkIn: string, checkOut: string, today: string): string {
  const checkInLabel = checkIn === today ? "اليوم" : formatWeekday(checkIn);
  return `${checkInLabel} ← ${formatWeekday(checkOut)}`;
}

function approvalTitle(action: string): string {
  const titles: Record<string, string> = {
    "booking.confirm": "تأكيد حجز",
    "booking.change": "تعديل حجز",
    "availability.block": "إغلاق توفر",
  };
  return titles[action] ?? "طلب يحتاج مراجعة";
}

function approvalUrgency(approval: LiveApprovalRow, today: string): DashboardApproval["urgency"] {
  return approval.expiresAt && approval.expiresAt.slice(0, 10) <= addDays(today, 1) ? "attention" : "normal";
}

function mapBooking(booking: LiveBookingRow, today: string, organizationId: OrganizationId): DashboardBooking {
  return {
    id: booking.id,
    organizationId,
    property: `${booking.propertyCode} · ${booking.propertyName}`,
    guest: booking.clientName?.trim() || "عميل غير مسجل",
    checkIn: booking.checkIn,
    checkOut: booking.checkOut,
    status: booking.status === "confirmed" ? "confirmed" : "pending_approval",
    stayLabel: stayLabel(booking.checkIn, booking.checkOut, today),
  };
}

function mapApproval(
  approval: LiveApprovalRow,
  bookingById: ReadonlyMap<string, LiveBookingRow>,
  today: string,
  organizationId: OrganizationId,
): DashboardApproval {
  const booking = bookingById.get(approval.resourceId);
  const detail = booking
    ? `${booking.propertyCode} · ${booking.propertyName} · ${booking.clientName?.trim() || "عميل غير مسجل"}`
    : `${approval.resourceType} · ${formatDateLabel(approval.createdAt.slice(0, 10))}`;

  return {
    id: approval.id,
    organizationId,
    title: approvalTitle(approval.proposedAction),
    detail,
    requestedBy: "مسار المراجعة",
    requestedAt: formatDateLabel(approval.createdAt.slice(0, 10)),
    urgency: approvalUrgency(approval, today),
  };
}

function occupancyPercentage(inputs: LiveDashboardInputs): number {
  const windowEnd = addDays(inputs.today, 7);
  const occupiedNights = inputs.bookings
    .filter((booking) => booking.status === "confirmed")
    .reduce((total, booking) => total + overlapNights(booking.checkIn, booking.checkOut, inputs.today, windowEnd), 0);
  const capacity = inputs.activePropertyCount * 7;
  if (capacity === 0) return 0;
  return Math.min(100, Math.max(0, Math.round((occupiedNights / capacity) * 100)));
}

export function buildDashboardData(inputs: LiveDashboardInputs): DashboardData {
  const bookings = liveBookingRows(inputs.bookings, inputs.today);
  const bookingById = new Map(inputs.bookings.map((booking) => [booking.id, booking]));
  const approvals = inputs.approvals
    .filter((approval) => approval.status === "pending")
    .slice(0, 3)
    .map((approval) => mapApproval(approval, bookingById, inputs.today, inputs.organizationId));
  const arrivalsToday = bookings.filter((booking) => booking.checkIn === inputs.today).length;

  return {
    isPreview: false,
    organizationId: inputs.organizationId,
    organizationName: inputs.organizationName,
    operatorName: inputs.operatorName,
    dateLabel: new Intl.DateTimeFormat("ar-EG", { weekday: "long", day: "numeric", month: "long" }).format(dateAtUtcMidnight(inputs.today)),
    dateRangeLabel: formatDateRangeLabel(inputs.today),
    metrics: [
      { label: "الإشغال هذا الأسبوع", value: `${occupancyPercentage(inputs)}٪`, change: "من الحجوزات المؤكدة", tone: "teal" },
      { label: "وصولات اليوم", value: String(arrivalsToday), change: arrivalsToday > 0 ? "تحتاج متابعة التشغيل" : "لا توجد وصولات اليوم", tone: "sand" },
      { label: "قرارات معلّقة", value: String(approvals.length), change: approvals.length > 0 ? "تحتاج مراجعتك" : "لا توجد قرارات معلّقة", tone: "coral" },
    ],
    bookings: bookings.map((booking) => mapBooking(booking, inputs.today, inputs.organizationId)),
    approvals,
  };
}

export async function loadLiveDashboardData(
  client: DashboardRpcClient,
  membership: Pick<WorkspaceMembership, "organizationId" | "organizationName">,
  operatorName = "فريق التشغيل",
  today = new Intl.DateTimeFormat("en-CA", { timeZone: "Africa/Cairo" }).format(new Date()),
): Promise<DashboardData> {
  const [bookingsResult, propertiesResult, approvalsResult] = await Promise.all([
    client.rpc("list_booking_work_queue", { p_organization_id: membership.organizationId }),
    client.rpc("list_properties", { p_organization_id: membership.organizationId }),
    client.rpc("list_approval_requests", { p_organization_id: membership.organizationId, p_limit: 50 }),
  ]);
  if (bookingsResult.error) throw bookingsResult.error;
  if (propertiesResult.error) throw propertiesResult.error;
  if (approvalsResult.error) throw approvalsResult.error;

  return buildDashboardData({
    organizationId: createOrganizationId(membership.organizationId),
    organizationName: membership.organizationName,
    operatorName,
    today,
    activePropertyCount: ((propertiesResult.data ?? []) as PropertyRpcRow[]).filter((property) => property.status === "active").length,
    bookings: ((bookingsResult.data ?? []) as BookingRpcRow[]).map((booking) => ({
      id: booking.id,
      propertyCode: booking.property_code,
      propertyName: booking.property_name,
      clientName: booking.client_name,
      status: booking.status,
      checkIn: booking.check_in,
      checkOut: booking.check_out,
      hasCheckIn: booking.has_check_in,
      hasCheckOut: booking.has_check_out,
      createdAt: booking.created_at,
    })),
    approvals: ((approvalsResult.data ?? []) as ApprovalRpcRow[]).map((approval) => ({
      id: approval.id,
      resourceType: approval.resource_type,
      resourceId: approval.resource_id,
      proposedAction: approval.proposed_action,
      status: approval.status,
      expiresAt: approval.expires_at,
      createdAt: approval.created_at,
    })),
  });
}
