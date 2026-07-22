"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import type { BookingDraftState } from "@/features/bookings/booking-draft-form";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

function formValue(formData: FormData, key: string) { const value = formData.get(key); return typeof value === "string" ? value.trim() : null; }

export async function createBookingDraftAction(_previousState: BookingDraftState, formData: FormData): Promise<BookingDraftState> {
  const propertyId = formValue(formData, "property_id"); const clientId = formValue(formData, "client_id"); const checkIn = formValue(formData, "check_in"); const checkOut = formValue(formData, "check_out"); const idempotencyKey = formValue(formData, "idempotency_key");
  if (!propertyId || !clientId || !checkIn || !checkOut || !idempotencyKey || checkIn >= checkOut) return { status: "invalid", message: "اختر العقار والعميل وتأكد أن المغادرة بعد الوصول." };
  try {
    const client = await createServerSupabaseClient(); const { data: userData } = await client.auth.getUser();
    if (!userData.user) return { status: "denied", message: "انتهت الجلسة. سجّل الدخول مرة أخرى." };
    const { data: memberships } = await client.from("organization_memberships").select("id, organization_id, role, status").eq("user_id", userData.user.id).limit(2);
    const membership = resolveActiveMembership((memberships ?? []).map((item) => ({ id: item.id, organizationId: item.organization_id, role: item.role, status: item.status })));
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لإنشاء مسودة." };
    const { error } = await client.rpc("create_booking_draft", { p_organization_id: membership.organizationId, p_property_id: propertyId, p_client_id: clientId, p_check_in: checkIn, p_check_out: checkOut, p_idempotency_key: idempotencyKey, p_request_id: randomUUID() });
    if (error) { if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إنشاء مسودة حجز." }; if (error.code === "22023" || error.code === "23503" || error.code === "23514") return { status: "invalid", message: "تحقق من بيانات المسودة ثم أعد المحاولة." }; return { status: "retry", message: "تعذر حفظ المسودة الآن. حاول مرة أخرى." }; }
    revalidatePath("/workspace/bookings"); return { status: "success", message: "تم إنشاء مسودة الحجز." };
  } catch (error) { if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." }; return { status: "retry", message: "تعذر حفظ المسودة الآن. حاول مرة أخرى." }; }
}
