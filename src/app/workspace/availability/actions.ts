"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import type { AvailabilityBlockState } from "@/features/availability/availability-block-create-form";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

function formValue(formData: FormData, key: string) { const value = formData.get(key); return typeof value === "string" ? value.trim() : null; }
export async function createAvailabilityBlockAction(_previousState: AvailabilityBlockState, formData: FormData): Promise<AvailabilityBlockState> {
  const propertyId = formValue(formData, "property_id"); const startDate = formValue(formData, "start_date"); const endDate = formValue(formData, "end_date"); const blockType = formValue(formData, "block_type"); const reason = formValue(formData, "reason") || null; const idempotencyKey = formValue(formData, "idempotency_key");
  if (!propertyId || !startDate || !endDate || !blockType || !idempotencyKey || startDate >= endDate) return { status: "invalid", message: "اختر العقار وتأكد أن نهاية الحظر بعد بدايته." };
  try { const client = await createServerSupabaseClient(); const { data: userData } = await client.auth.getUser(); if (!userData.user) return { status: "denied", message: "انتهت الجلسة. سجّل الدخول مرة أخرى." }; const { data: memberships } = await client.from("organization_memberships").select("id, organization_id, role, status").eq("user_id", userData.user.id).limit(2); const membership = resolveActiveMembership((memberships ?? []).map((item) => ({ id: item.id, organizationId: item.organization_id, role: item.role, status: item.status }))); if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." }; const { error } = await client.rpc("create_availability_block", { p_organization_id: membership.organizationId, p_property_id: propertyId, p_start_date: startDate, p_end_date: endDate, p_block_type: blockType, p_reason: reason, p_idempotency_key: idempotencyKey, p_request_id: randomUUID() }); if (error) { if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إضافة حظر." }; if (["22023", "23503", "23514", "23P01"].includes(error.code ?? "")) return { status: "invalid", message: "يتعارض الحظر مع بيانات العقار أو إشغاله المؤكد." }; return { status: "retry", message: "تعذر حفظ الحظر الآن. حاول مرة أخرى." }; } revalidatePath("/workspace/availability"); return { status: "success", message: "تمت إضافة حظر التوفر." }; } catch (error) { if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." }; return { status: "retry", message: "تعذر حفظ الحظر الآن. حاول مرة أخرى." }; }
}
