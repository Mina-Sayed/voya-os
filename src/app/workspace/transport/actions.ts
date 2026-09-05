"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { TransportActionState } from "@/features/transport/transport-operations-page";
import { parseIsoDateTime } from "@/domain/time/iso-datetime";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

const value = (formData: FormData, key: string) => {
  const raw = formData.get(key);
  return typeof raw === "string" ? raw.trim() : null;
};

function mapError(error: { code?: string | null }, deniedMessage: string, invalidMessage: string): TransportActionState {
  if (error.code === "42501") return { status: "denied", message: deniedMessage };
  if (["22003", "22023", "23P01", "23503", "23505", "23514", "40001"].includes(error.code ?? "")) return { status: "invalid", message: invalidMessage };
  return { status: "retry", message: "تعذر حفظ التغيير الآن. حاول مرة أخرى." };
}

export async function createFleetVehicleAction(_previousState: TransportActionState, formData: FormData): Promise<TransportActionState> {
  const displayName = value(formData, "display_name");
  const vehicleType = value(formData, "vehicle_type");
  const registrationCode = value(formData, "registration_code");
  const passengerCapacity = Number(value(formData, "passenger_capacity"));
  const idempotencyKey = value(formData, "idempotency_key");
  const requestId = randomUUID();
  if (!displayName || !vehicleType || !registrationCode || !idempotencyKey || !Number.isInteger(passengerCapacity)) return { status: "invalid", message: "أكمل بيانات المركبة." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager", "operations"].includes(membership.role)) return { status: "denied", message: "إدارة المركبات متاحة لفريق التشغيل والمدير فقط." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_fleet_vehicle_v1", {
      p_organization_id: membership.organizationId,
      p_display_name: displayName,
      p_vehicle_type: vehicleType,
      p_registration_code: registrationCode,
      p_passenger_capacity: passengerCapacity,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية إضافة مركبة.", "تحقق من البيانات أو رمز المركبة أو أعد إرسال نفس المحاولة دون تغيير البيانات.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.transport.vehicle.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/transport");
    return { status: "success", message: "تم تسجيل المركبة." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.transport.vehicle.create", error, requestId);
    return { status: "retry", message: "تعذر تسجيل المركبة الآن." };
  }
}

export async function createFleetDriverAction(_previousState: TransportActionState, formData: FormData): Promise<TransportActionState> {
  const displayName = value(formData, "display_name");
  const phoneE164 = value(formData, "phone_e164") || null;
  const idempotencyKey = value(formData, "idempotency_key");
  const requestId = randomUUID();
  if (!displayName || !idempotencyKey) return { status: "invalid", message: "اكتب اسم السائق." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager", "operations"].includes(membership.role)) return { status: "denied", message: "إدارة السائقين متاحة لفريق التشغيل والمدير فقط." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_fleet_driver_v1", {
      p_organization_id: membership.organizationId,
      p_display_name: displayName,
      p_phone_e164: phoneE164,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية إضافة سائق.", "تحقق من الاسم أو رقم الهاتف أو أعد إرسال نفس المحاولة دون تغيير البيانات.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.transport.driver.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/transport");
    return { status: "success", message: "تم تسجيل السائق." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.transport.driver.create", error, requestId);
    return { status: "retry", message: "تعذر تسجيل السائق الآن." };
  }
}

export async function createTransportRequestAction(_previousState: TransportActionState, formData: FormData): Promise<TransportActionState> {
  const requestType = value(formData, "request_type");
  const guestLabel = value(formData, "guest_label");
  const pickupLocation = value(formData, "pickup_location");
  const dropoffLocation = value(formData, "dropoff_location");
  const pickupAt = value(formData, "pickup_at");
  const returnAt = value(formData, "return_at") || null;
  const passengerCount = Number(value(formData, "passenger_count"));
  const notes = value(formData, "notes") || null;
  const idempotencyKey = value(formData, "idempotency_key");
  const requestId = randomUUID();
  if (!requestType || !["airport_transfer", "car_rental"].includes(requestType)) return { status: "invalid", message: "نوع الطلب يجب أن يكون تحويل مطار أو تأجير سيارة." };
  if (!guestLabel || !pickupLocation || !dropoffLocation || !pickupAt || !idempotencyKey || !Number.isInteger(passengerCount)) return { status: "invalid", message: "أكمل بيانات طلب النقل: الضيف، نقاط الالتقاط/الوصول، التوقيت وعدد الركاب." };
  if (passengerCount < 1 || passengerCount > 80) return { status: "invalid", message: "عدد الركاب يجب أن يكون بين 1 و 80." };
  const pickupAtIso = parseIsoDateTime(pickupAt);
  const returnAtIso = returnAt ? parseIsoDateTime(returnAt) : null;
  if (!pickupAtIso || (returnAt && !returnAtIso)) return { status: "invalid", message: "تحقق من توقيت طلب النقل بصيغة صحيحة (مثال: 2027-01-10T12:00)." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager", "sales_agent", "operations"].includes(membership.role)) return { status: "denied", message: "إنشاء طلب نقل غير متاح لدورك." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_transport_request", { p_organization_id: membership.organizationId, p_request_type: requestType, p_guest_label: guestLabel, p_pickup_location: pickupLocation, p_dropoff_location: dropoffLocation, p_pickup_at: pickupAtIso, p_passenger_count: passengerCount, p_return_at: returnAtIso, p_booking_id: null, p_notes: notes, p_idempotency_key: idempotencyKey, p_request_id: requestId });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية إنشاء طلب نقل.", "تحقق من نوع الطلب (تحويل مطار/تأجير سيارة)، المواقع (1-240 حرف)، التوقيت وعدد الركاب (1-80).");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.transport.request.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/transport");
    return { status: "success", message: "تم تسجيل طلب النقل في قائمة التشغيل." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.transport.request.create", error, requestId);
    return { status: "retry", message: "تعذر تسجيل طلب النقل الآن." };
  }
}

export async function assignTransportRequestAction(_previousState: TransportActionState, formData: FormData): Promise<TransportActionState> {
  const requestId = value(formData, "request_id");
  const vehicleId = value(formData, "vehicle_id") || null;
  const driverId = value(formData, "driver_id") || null;
  const correlationId = randomUUID();
  if (!requestId) return { status: "invalid", message: "طلب النقل غير معروف." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager", "operations"].includes(membership.role)) return { status: "denied", message: "الإسناد متاح لفريق التشغيل والمدير فقط." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("assign_transport_request", { p_organization_id: membership.organizationId, p_request_id: requestId, p_vehicle_id: vehicleId, p_driver_id: driverId, p_request_idempotency: correlationId });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية إسناد الطلب.", "اختر مركبة وسائقاً متاحين.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.transport.request.assign", error, correlationId);
      return result;
    }
    revalidatePath("/workspace/transport");
    return { status: "success", message: "تم تحديث إسناد الطلب." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.transport.request.assign", error, correlationId);
    return { status: "retry", message: "تعذر تحديث الإسناد الآن." };
  }
}

export async function updateTransportRequestStatusAction(requestId: string, status: string): Promise<TransportActionState> {
  const correlationId = randomUUID();
  if (!requestId || !["requested", "assigned", "in_progress", "completed", "cancelled"].includes(status)) {
    return { status: "invalid", message: "حالة طلب النقل غير صالحة." };
  }
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager", "operations"].includes(membership.role)) {
      return { status: "denied", message: "تحديث حالة النقل متاح لفريق التشغيل والمدير فقط." };
    }
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("update_transport_request_status", { p_organization_id: membership.organizationId, p_request_id: requestId, p_status: status, p_request_idempotency: correlationId });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية تحديث حالة طلب النقل.", "لا يمكن تطبيق حالة طلب النقل المطلوبة.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.transport.request.status", error, correlationId);
      return result;
    }
    revalidatePath("/workspace/transport");
    return { status: "success", message: "تم تحديث حالة طلب النقل." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.transport.request.status", error, correlationId);
    return { status: "retry", message: "تعذر تحديث حالة طلب النقل الآن." };
  }
}
