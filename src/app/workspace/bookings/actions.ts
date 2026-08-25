"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { parseMajorToMinor } from "@/domain/money/minor-units";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { BookingDraftState } from "@/features/bookings/booking-draft-form";
import type { BookingLifecycleActionState } from "@/features/bookings/bookings-page";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

function formValue(formData: FormData, key: string) { const value = formData.get(key); return typeof value === "string" ? value.trim() : null; }

function amountMinor(formData: FormData, currency: string | null) {
  const amount = formValue(formData, "amount");
  if (!amount || !currency) return null;
  try { return parseMajorToMinor(amount, currency); } catch { return null; }
}

export async function createBookingDraftAction(_previousState: BookingDraftState, formData: FormData): Promise<BookingDraftState> {
  const propertyId = formValue(formData, "property_id"); const clientId = formValue(formData, "client_id"); const checkIn = formValue(formData, "check_in"); const checkOut = formValue(formData, "check_out"); const currency = formValue(formData, "currency"); const idempotencyKey = formValue(formData, "idempotency_key"); const minor = amountMinor(formData, currency);
  if (!propertyId || !clientId || !checkIn || !checkOut || !minor || !currency || !idempotencyKey || checkIn >= checkOut || !/^[A-Z]{3}$/.test(currency)) return { status: "invalid", message: "أكمل العقار والعميل والتواريخ والمبلغ والعملة بشكل صحيح." };
  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لإنشاء مسودة." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_commercial_booking_draft", { p_organization_id: membership.organizationId, p_property_id: propertyId, p_client_id: clientId, p_check_in: checkIn, p_check_out: checkOut, p_amount_minor: minor, p_currency: currency, p_idempotency_key: idempotencyKey, p_request_id: requestId });
    if (error) { if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إنشاء مسودة حجز." }; if (["22003", "22023", "23503", "23514"].includes(error.code ?? "")) return { status: "invalid", message: "تحقق من بيانات المسودة ثم أعد المحاولة." }; reportWorkspaceActionFailure("workspace.booking.create", error, requestId); return { status: "retry", message: "تعذر حفظ المسودة الآن. حاول مرة أخرى." }; }
    revalidatePath("/workspace/bookings"); return { status: "success", message: "تم إنشاء مسودة الحجز التجاري." };
  } catch (error) { reportWorkspaceActionFailure("workspace.booking.create", error, requestId); if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." }; return { status: "retry", message: "تعذر حفظ المسودة الآن. حاول مرة أخرى." }; }
}

function lifecycleValue(formData: FormData, key: string) { const raw = formData.get(key); return typeof raw === "string" ? raw.trim() : null; }

function lifecycleError(error: { code?: string | null }, deniedMessage: string, invalidMessage: string): BookingLifecycleActionState {
  if (error.code === "42501") return { status: "denied", message: deniedMessage };
  if (["22003", "22023", "23503", "23505", "23P01", "23514"].includes(error.code ?? "")) return { status: "invalid", message: invalidMessage };
  return { status: "retry", message: "تعذر تحديث دورة الحجز الآن." };
}

async function runBookingLifecycleCommand(rpc: string, formData: FormData, parameters: Record<string, string | null>, deniedMessage: string, invalidMessage: string, successMessage: string): Promise<BookingLifecycleActionState> {
  const bookingId = lifecycleValue(formData, "booking_id"); const idempotencyKey = lifecycleValue(formData, "idempotency_key"); const requestId = randomUUID();
  if (!bookingId || !idempotencyKey) return { status: "invalid", message: "تعذر تحديد الحجز أو مفتاح المحاولة." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc(rpc, { p_organization_id: membership.organizationId, p_booking_id: bookingId, p_idempotency_key: idempotencyKey, p_request_id: requestId, ...parameters });
    if (error) { const result = lifecycleError(error, deniedMessage, invalidMessage); if (result.status === "retry") reportWorkspaceActionFailure(`workspace.booking.${rpc}`, error, requestId); return result; }
    revalidatePath("/workspace/bookings"); revalidatePath("/workspace/approvals"); return { status: "success", message: successMessage };
  } catch (error) { reportWorkspaceActionFailure(`workspace.booking.${rpc}`, error, requestId); return { status: "retry", message: "تعذر تحديث دورة الحجز الآن." }; }
}

export async function requestBookingApprovalAction(_previousState: BookingLifecycleActionState, formData: FormData): Promise<BookingLifecycleActionState> { return runBookingLifecycleCommand("request_commercial_booking_approval", formData, {}, "لا تملك صلاحية طلب اعتماد.", "الحجز يحتاج snapshot تجاري مكتملًا أو لم يعد في حالة تسمح بطلب الاعتماد.", "تم إرسال الحجز التجاري إلى مسار الاعتماد."); }
export async function confirmBookingAction(_previousState: BookingLifecycleActionState, formData: FormData): Promise<BookingLifecycleActionState> { return runBookingLifecycleCommand("confirm_commercial_booking", formData, {}, "لا تملك صلاحية تأكيد الحجز.", "لا يمكن تأكيد الحجز قبل اعتماد صالح أو بسبب تعارض في التوفر.", "تم تأكيد الحجز التجاري بعد الاعتماد."); }

export async function cancelBookingDraftAction(_previousState: BookingLifecycleActionState, formData: FormData): Promise<BookingLifecycleActionState> {
  const reason = lifecycleValue(formData, "reason"); if (!reason) return { status: "invalid", message: "اكتب سبب إلغاء المسودة." };
  return runBookingLifecycleCommand("cancel_booking_draft", formData, { p_reason: reason }, "لا تملك صلاحية إلغاء المسودة.", "تعذر إلغاء المسودة في حالتها الحالية.", "تم إلغاء المسودة.");
}

export async function completeBookingCommercialSnapshotAction(_previousState: BookingLifecycleActionState, formData: FormData): Promise<BookingLifecycleActionState> {
  const currency = lifecycleValue(formData, "currency"); const minor = amountMinor(formData, currency); const reason = lifecycleValue(formData, "reason");
  if (!minor || !currency || !reason) return { status: "invalid", message: "أدخل المبلغ والسبب بشكل صحيح." };
  return runBookingLifecycleCommand("complete_booking_commercial_snapshot", formData, { p_amount_minor: minor, p_currency: currency, p_reason: reason }, "استكمال snapshot التجاري متاح للمالك أو المدير فقط.", "لا يمكن تعديل snapshot مكتمل؛ استخدم مسار التعديل المعتمد.", "تم استكمال snapshot التجاري للحجز التاريخي.");
}

export async function requestBookingAmendmentAction(_previousState: BookingLifecycleActionState, formData: FormData): Promise<BookingLifecycleActionState> {
  const currency = lifecycleValue(formData, "currency"); const minor = amountMinor(formData, currency); const propertyId = lifecycleValue(formData, "property_id"); const clientId = lifecycleValue(formData, "client_id"); const checkIn = lifecycleValue(formData, "check_in"); const checkOut = lifecycleValue(formData, "check_out"); const reason = lifecycleValue(formData, "reason");
  if (!minor || !currency || !propertyId || !clientId || !checkIn || !checkOut || checkIn >= checkOut || !reason) return { status: "invalid", message: "تحقق من تفاصيل التعديل وسببه." };
  return runBookingLifecycleCommand("request_booking_amendment", formData, { p_property_id: propertyId, p_client_id: clientId, p_check_in: checkIn, p_check_out: checkOut, p_amount_minor: minor, p_currency: currency, p_reason: reason }, "لا تملك صلاحية طلب تعديل الحجز.", "التعديل غير صالح للحالة الحالية أو يغيّر بيانات مجمّدة بعد الوصول.", "تم إرسال تعديل الحجز للاعتماد.");
}

export async function executeBookingAmendmentAction(_previousState: BookingLifecycleActionState, formData: FormData): Promise<BookingLifecycleActionState> { return runBookingLifecycleCommand("execute_booking_amendment", formData, {}, "تنفيذ التعديل المعتمد متاح للمالك أو المدير فقط.", "لا يوجد تعديل معتمد صالح للتنفيذ.", "تم تنفيذ التعديل المعتمد."); }

export async function requestBookingCancellationAction(_previousState: BookingLifecycleActionState, formData: FormData): Promise<BookingLifecycleActionState> {
  const reason = lifecycleValue(formData, "reason"); if (!reason) return { status: "invalid", message: "اكتب سبب طلب الإلغاء." };
  return runBookingLifecycleCommand("request_booking_cancellation", formData, { p_reason: reason }, "لا تملك صلاحية طلب إلغاء الحجز.", "لا يمكن طلب الإلغاء في الحالة الحالية.", "تم إرسال طلب الإلغاء للاعتماد.");
}

export async function executeBookingCancellationAction(_previousState: BookingLifecycleActionState, formData: FormData): Promise<BookingLifecycleActionState> { return runBookingLifecycleCommand("execute_booking_cancellation", formData, {}, "تنفيذ الإلغاء المعتمد متاح للمالك أو المدير فقط.", "لا يوجد طلب إلغاء معتمد صالح للتنفيذ.", "تم تنفيذ إلغاء الحجز وتحرير الإشغال."); }

export async function recordBookingStayEventAction(_previousState: BookingLifecycleActionState, formData: FormData): Promise<BookingLifecycleActionState> {
  const eventType = lifecycleValue(formData, "event_type"); if (!eventType || !["check_in", "check_out"].includes(eventType)) return { status: "invalid", message: "نوع حدث الإقامة غير صالح." };
  return runBookingLifecycleCommand("record_commercial_booking_stay_event", formData, { p_event_type: eventType, p_notes: lifecycleValue(formData, "notes") }, "لا تملك صلاحية تسجيل حدث الإقامة.", "تحقق من حالة الحجز وتسلسل الوصول والمغادرة أو مفتاح المحاولة.", eventType === "check_in" ? "تم تسجيل الوصول." : "تم تسجيل المغادرة وإكمال الإقامة.");
}
