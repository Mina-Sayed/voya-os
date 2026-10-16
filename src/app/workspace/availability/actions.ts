"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { AvailabilityBlockState } from "@/features/availability/availability-block-create-form";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

function formValue(formData: FormData, key: string) { const value = formData.get(key); return typeof value === "string" ? value.trim() : null; }
export async function createAvailabilityBlockAction(_previousState: AvailabilityBlockState, formData: FormData): Promise<AvailabilityBlockState> {
  const propertyId = formValue(formData, "property_id"); const startDate = formValue(formData, "start_date"); const endDate = formValue(formData, "end_date"); const blockType = formValue(formData, "block_type"); const reason = formValue(formData, "reason") || null; const idempotencyKey = formValue(formData, "idempotency_key");
  if (!propertyId || !startDate || !endDate || !blockType || !idempotencyKey || startDate >= endDate) return { status: "invalid", message: "اختر العقار وتأكد أن نهاية الحظر بعد بدايته." };
  const requestId = randomUUID();
  try { const membership = await loadActionWorkspaceMembership(); if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." }; const client = await createServerSupabaseClient(); const { error } = await client.rpc("create_availability_block", { p_organization_id: membership.organizationId, p_property_id: propertyId, p_start_date: startDate, p_end_date: endDate, p_block_type: blockType, p_reason: reason, p_idempotency_key: idempotencyKey, p_request_id: requestId }); if (error) { if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إضافة حظر." }; if (["22023", "23503", "23514", "23P01"].includes(error.code ?? "")) return { status: "invalid", message: "يتعارض الحظر مع بيانات العقار أو إشغاله المؤكد." }; reportWorkspaceActionFailure("workspace.availability.create", error, requestId); return { status: "retry", message: "تعذر حفظ الحظر الآن. حاول مرة أخرى." }; } revalidatePath("/workspace/availability"); return { status: "success", message: "تمت إضافة حظر التوفر." }; } catch (error) { reportWorkspaceActionFailure("workspace.availability.create", error, requestId); if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." }; return { status: "retry", message: "تعذر حفظ الحظر الآن. حاول مرة أخرى." }; }
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;
const blockTypes = new Set(["maintenance", "owner_use", "administrative"]);

export async function updateAvailabilityBlockAction(_previousState: AvailabilityBlockState, formData: FormData): Promise<AvailabilityBlockState> {
  const blockId = formValue(formData, "block_id"); const startDate = formValue(formData, "start_date"); const endDate = formValue(formData, "end_date"); const blockType = formValue(formData, "block_type"); const reason = formValue(formData, "reason") || null;
  if (!blockId || !uuidPattern.test(blockId) || !startDate || !endDate || !blockType || !blockTypes.has(blockType) || startDate >= endDate || (reason?.length ?? 0) > 500) return { status: "invalid", message: "تأكد أن نهاية الحظر بعد بدايته." };
  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("update_availability_block_v1", { p_organization_id: membership.organizationId, p_block_id: blockId, p_start_date: startDate, p_end_date: endDate, p_block_type: blockType, p_reason: reason, p_request_id: requestId });
    if (error) {
      if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية تعديل الحظر." };
      if (error.code === "P0002") return { status: "invalid", message: "لم يعد هذا الحظر موجوداً." };
      if (["22023", "23514", "23P01"].includes(error.code ?? "")) return { status: "invalid", message: "يتعارض الحظر مع إشغال مؤكد أو بيانات غير صالحة." };
      reportWorkspaceActionFailure("workspace.availability.update", error, requestId);
      return { status: "retry", message: "تعذر تعديل الحظر الآن. حاول مرة أخرى." };
    }
    revalidatePath("/workspace/availability");
    return { status: "success", message: "تم تعديل الحظر." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.availability.update", error, requestId);
    return { status: "retry", message: error instanceof SupabaseConfigurationError ? "الخدمة غير مهيأة في هذه البيئة." : "تعذر تعديل الحظر الآن. حاول مرة أخرى." };
  }
}

export async function deleteAvailabilityBlockAction(_previousState: AvailabilityBlockState, formData: FormData): Promise<AvailabilityBlockState> {
  const blockId = formValue(formData, "block_id");
  if (!blockId || !uuidPattern.test(blockId)) return { status: "invalid", message: "تعذر تحديد الحظر." };
  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("delete_availability_block_v1", { p_organization_id: membership.organizationId, p_block_id: blockId, p_request_id: requestId });
    if (error) {
      if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية حذف الحظر." };
      reportWorkspaceActionFailure("workspace.availability.delete", error, requestId);
      return { status: "retry", message: "تعذر حذف الحظر الآن. حاول مرة أخرى." };
    }
    revalidatePath("/workspace/availability");
    return { status: "success", message: "تم حذف الحظر." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.availability.delete", error, requestId);
    return { status: "retry", message: error instanceof SupabaseConfigurationError ? "الخدمة غير مهيأة في هذه البيئة." : "تعذر حذف الحظر الآن. حاول مرة أخرى." };
  }
}
