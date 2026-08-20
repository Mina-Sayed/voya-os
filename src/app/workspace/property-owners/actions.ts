"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { PropertyOwnerCreateState } from "@/features/property-owners/property-owner-create-form";
import type { PropertyOwnerMutationState } from "@/features/property-owners/property-owner-command-state";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

function formValue(formData: FormData, key: string): string | null {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : null;
}

function optionalFormValue(formData: FormData, key: string): string | null {
  const value = formValue(formData, key);
  return value || null;
}

function versionValue(formData: FormData): number | null {
  const value = formValue(formData, "expected_version");
  if (!value || !/^\d+$/u.test(value)) return null;
  const version = Number(value);
  return Number.isSafeInteger(version) && version > 0 ? version : null;
}

function contactMethodValue(formData: FormData): string | null {
  const value = optionalFormValue(formData, "preferred_contact_method");
  return value === null || ["phone", "whatsapp", "email", "none"].includes(value) ? value : "invalid";
}

function ownerCommandError(error: { code?: string }, invalidMessage: string): PropertyOwnerMutationState {
  if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إدارة هذا المالك." };
  if (["22023", "23503", "23505", "40001"].includes(error.code ?? "")) return { status: "invalid", message: invalidMessage };
  return { status: "retry", message: "تعذر حفظ بيانات المالك الآن. حاول مرة أخرى." };
}

export async function createPropertyOwnerAction(
  _previousState: PropertyOwnerCreateState,
  formData: FormData,
): Promise<PropertyOwnerCreateState> {
  const displayName = formValue(formData, "display_name");
  const idempotencyKey = formValue(formData, "idempotency_key");
  const preferredContactMethod = contactMethodValue(formData);
  if (!displayName || !idempotencyKey || preferredContactMethod === "invalid") {
    return { status: "invalid", message: "اكتب اسم المالك للمتابعة." };
  }
  const requestId = randomUUID();

  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لإضافة مالك." };
    const client = await createServerSupabaseClient();

    const { error } = await client.rpc("create_property_owner_v1", {
      p_organization_id: membership.organizationId,
      p_display_name: displayName,
      p_phone: optionalFormValue(formData, "phone"),
      p_whatsapp: optionalFormValue(formData, "whatsapp"),
      p_email: optionalFormValue(formData, "email"),
      p_preferred_contact_method: preferredContactMethod,
      p_notes: optionalFormValue(formData, "notes"),
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إضافة مالك." };
      if (error.code === "22023") return { status: "invalid", message: "تحقق من اسم المالك ثم أعد المحاولة." };
      reportWorkspaceActionFailure("workspace.property_owner.create", error, requestId);
      return { status: "retry", message: "تعذر حفظ المالك الآن. حاول مرة أخرى." };
    }

    revalidatePath("/workspace/property-owners");
    return { status: "success", message: "تمت إضافة المالك." };
  } catch (error) { reportWorkspaceActionFailure("workspace.property_owner.create", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر حفظ المالك الآن. حاول مرة أخرى." };
  }
}

export async function updatePropertyOwnerAction(
  _previousState: PropertyOwnerMutationState,
  formData: FormData,
): Promise<PropertyOwnerMutationState> {
  const propertyOwnerId = formValue(formData, "property_owner_id");
  const displayName = formValue(formData, "display_name");
  const status = formValue(formData, "status");
  const expectedVersion = versionValue(formData);
  const idempotencyKey = formValue(formData, "idempotency_key");
  const preferredContactMethod = contactMethodValue(formData);
  if (!propertyOwnerId || !displayName || !idempotencyKey || !expectedVersion || !["active", "inactive"].includes(status ?? "") || preferredContactMethod === "invalid") {
    return { status: "invalid", message: "أكمل بيانات المالك قبل الحفظ." };
  }
  const requestId = randomUUID();

  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لتعديل المالك." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("update_property_owner_v1", {
      p_organization_id: membership.organizationId,
      p_property_owner_id: propertyOwnerId,
      p_display_name: displayName,
      p_phone: optionalFormValue(formData, "phone"),
      p_whatsapp: optionalFormValue(formData, "whatsapp"),
      p_email: optionalFormValue(formData, "email"),
      p_preferred_contact_method: preferredContactMethod,
      p_notes: optionalFormValue(formData, "notes"),
      p_status: status,
      p_expected_version: expectedVersion,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = ownerCommandError(error, "تغيرت بيانات المالك أو لم تعد العملية صالحة. أعد تحميل الصفحة وحاول مرة أخرى.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.property_owner.update", error, requestId);
      return result;
    }
    revalidatePath("/workspace/property-owners");
    return { status: "success", message: "تم تحديث بيانات المالك." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.property_owner.update", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر حفظ بيانات المالك الآن. حاول مرة أخرى." };
  }
}

export async function archivePropertyOwnerAction(
  _previousState: PropertyOwnerMutationState,
  formData: FormData,
): Promise<PropertyOwnerMutationState> {
  const propertyOwnerId = formValue(formData, "property_owner_id");
  const reason = formValue(formData, "reason");
  const expectedVersion = versionValue(formData);
  const idempotencyKey = formValue(formData, "idempotency_key");
  if (!propertyOwnerId || !reason || !expectedVersion || !idempotencyKey) return { status: "invalid", message: "اكتب سبب الأرشفة وأكمل بيانات العملية." };
  const requestId = randomUUID();

  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لأرشفة المالك." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("archive_property_owner_v1", {
      p_organization_id: membership.organizationId,
      p_property_owner_id: propertyOwnerId,
      p_reason: reason,
      p_expected_version: expectedVersion,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = ownerCommandError(error, "تغيرت بيانات المالك أو لم تعد الأرشفة صالحة.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.property_owner.archive", error, requestId);
      return result;
    }
    revalidatePath("/workspace/property-owners");
    revalidatePath("/workspace/properties");
    return { status: "success", message: "تمت أرشفة المالك." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.property_owner.archive", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر أرشفة المالك الآن." };
  }
}

export async function restorePropertyOwnerAction(
  _previousState: PropertyOwnerMutationState,
  formData: FormData,
): Promise<PropertyOwnerMutationState> {
  const propertyOwnerId = formValue(formData, "property_owner_id");
  const expectedVersion = versionValue(formData);
  const idempotencyKey = formValue(formData, "idempotency_key");
  if (!propertyOwnerId || !expectedVersion || !idempotencyKey) return { status: "invalid", message: "بيانات استعادة المالك غير مكتملة." };
  const requestId = randomUUID();

  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لاستعادة المالك." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("restore_property_owner_v1", {
      p_organization_id: membership.organizationId,
      p_property_owner_id: propertyOwnerId,
      p_expected_version: expectedVersion,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = ownerCommandError(error, "تغيرت بيانات المالك أو لم تعد الاستعادة صالحة.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.property_owner.restore", error, requestId);
      return result;
    }
    revalidatePath("/workspace/property-owners");
    revalidatePath("/workspace/properties");
    return { status: "success", message: "تمت استعادة المالك." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.property_owner.restore", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر استعادة المالك الآن." };
  }
}
