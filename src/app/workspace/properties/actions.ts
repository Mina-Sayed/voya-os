"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { PropertyCreateState } from "@/features/properties/property-create-form";
import type { PropertyMutationState } from "@/features/properties/property-command-state";
import type { PropertyImageUploadState } from "@/features/properties/property-image-upload-form";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServiceRoleSupabaseClient, createServerSupabaseClient } from "@/lib/supabase/server-auth";

function formValue(formData: FormData, key: string): string | null {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : null;
}

function optionalFormValue(formData: FormData, key: string): string | null {
  const value = formValue(formData, key);
  return value || null;
}

function integerValue(formData: FormData, key: string): number | null | "invalid" {
  const value = optionalFormValue(formData, key);
  if (value === null) return null;
  if (!/^\d+$/u.test(value)) return "invalid";
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : "invalid";
}

function commandError(error: { code?: string }, invalidMessage: string): PropertyMutationState {
  if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية تعديل هذا العقار." };
  if (["22023", "23503", "23505", "40001"].includes(error.code ?? "")) return { status: "invalid", message: invalidMessage };
  return { status: "retry", message: "تعذر حفظ بيانات العقار الآن. حاول مرة أخرى." };
}

export async function createPropertyAction(
  _previousState: PropertyCreateState,
  formData: FormData,
): Promise<PropertyCreateState> {
  const code = formValue(formData, "code");
  const name = formValue(formData, "name");
  const timezone = formValue(formData, "timezone");
  const address = optionalFormValue(formData, "address");
  const city = optionalFormValue(formData, "city");
  const unitLabel = optionalFormValue(formData, "unit_label");
  const operationalNotes = optionalFormValue(formData, "operational_notes");
  const bedrooms = integerValue(formData, "bedrooms");
  const maxGuests = integerValue(formData, "max_guests");
  const idempotencyKey = formValue(formData, "idempotency_key");
  if (!code || !name || !timezone || !idempotencyKey || bedrooms === "invalid" || maxGuests === "invalid") return { status: "invalid", message: "أكمل بيانات العقار بصيغة صحيحة للمتابعة." };
  const requestId = randomUUID();

  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لإضافة عقار." };
    const client = await createServerSupabaseClient();

    const { error } = await client.rpc("create_property_v1", {
      p_organization_id: membership.organizationId,
      p_code: code,
      p_name: name,
      p_timezone: timezone,
      p_address: address,
      p_city: city,
      p_unit_label: unitLabel,
      p_bedrooms: bedrooms,
      p_max_guests: maxGuests,
      p_operational_notes: operationalNotes,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إضافة عقار." };
      if (error.code === "22023") return { status: "invalid", message: "تحقق من بيانات العقار ثم أعد المحاولة." };
      reportWorkspaceActionFailure("workspace.property.create", error, requestId);
      return { status: "retry", message: "تعذر حفظ العقار الآن. حاول مرة أخرى." };
    }
    revalidatePath("/workspace/properties");
    return { status: "success", message: "تمت إضافة العقار." };
  } catch (error) { reportWorkspaceActionFailure("workspace.property.create", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر حفظ العقار الآن. حاول مرة أخرى." };
  }
}

export async function updatePropertyAction(
  _previousState: PropertyMutationState,
  formData: FormData,
): Promise<PropertyMutationState> {
  const propertyId = formValue(formData, "property_id");
  const code = formValue(formData, "code");
  const name = formValue(formData, "name");
  const timezone = formValue(formData, "timezone");
  const status = formValue(formData, "status");
  const expectedVersionRaw = formValue(formData, "expected_version");
  const idempotencyKey = formValue(formData, "idempotency_key");
  const bedrooms = integerValue(formData, "bedrooms");
  const maxGuests = integerValue(formData, "max_guests");
  const expectedVersion = expectedVersionRaw && /^\d+$/u.test(expectedVersionRaw) ? Number(expectedVersionRaw) : null;
  if (!propertyId || !code || !name || !timezone || !idempotencyKey || !expectedVersion || !["active", "inactive"].includes(status ?? "") || bedrooms === "invalid" || maxGuests === "invalid") {
    return { status: "invalid", message: "أكمل بيانات العقار قبل الحفظ." };
  }
  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لتعديل العقار." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("update_property_v1", {
      p_organization_id: membership.organizationId,
      p_property_id: propertyId,
      p_code: code,
      p_name: name,
      p_timezone: timezone,
      p_address: optionalFormValue(formData, "address"),
      p_city: optionalFormValue(formData, "city"),
      p_unit_label: optionalFormValue(formData, "unit_label"),
      p_bedrooms: bedrooms,
      p_max_guests: maxGuests,
      p_operational_notes: optionalFormValue(formData, "operational_notes"),
      p_status: status,
      p_expected_version: expectedVersion,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = commandError(error, "تغيرت بيانات العقار أو لم تعد العملية صالحة. أعد تحميل الصفحة وحاول مرة أخرى.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.property.update", error, requestId);
      return result;
    }
    revalidatePath("/workspace/properties");
    return { status: "success", message: "تم تحديث بيانات العقار." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.property.update", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر حفظ بيانات العقار الآن. حاول مرة أخرى." };
  }
}

export async function archivePropertyAction(
  _previousState: PropertyMutationState,
  formData: FormData,
): Promise<PropertyMutationState> {
  const propertyId = formValue(formData, "property_id");
  const reason = formValue(formData, "reason");
  const expectedVersionRaw = formValue(formData, "expected_version");
  const idempotencyKey = formValue(formData, "idempotency_key");
  const expectedVersion = expectedVersionRaw && /^\d+$/u.test(expectedVersionRaw) ? Number(expectedVersionRaw) : null;
  if (!propertyId || !reason || !expectedVersion || !idempotencyKey) return { status: "invalid", message: "اكتب سبب الأرشفة قبل المتابعة." };
  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لأرشفة العقار." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("archive_property_v1", {
      p_organization_id: membership.organizationId,
      p_property_id: propertyId,
      p_reason: reason,
      p_expected_version: expectedVersion,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = commandError(error, "تغيرت بيانات العقار أو لم تعد الأرشفة صالحة.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.property.archive", error, requestId);
      return result;
    }
    revalidatePath("/workspace/properties");
    return { status: "success", message: "تمت أرشفة العقار." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.property.archive", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر أرشفة العقار الآن." };
  }
}

function isIsoDate(value: string | null): value is string {
  return value !== null && /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/u.test(value);
}

export async function assignPropertyOwnerAction(
  _previousState: PropertyMutationState,
  formData: FormData,
): Promise<PropertyMutationState> {
  const propertyId = formValue(formData, "property_id");
  const propertyOwnerId = formValue(formData, "property_owner_id");
  const startDate = formValue(formData, "start_date");
  const endDate = formValue(formData, "end_date");
  const idempotencyKey = formValue(formData, "idempotency_key");
  if (!propertyId || !propertyOwnerId || !isIsoDate(startDate) || !isIsoDate(endDate) || startDate >= endDate || !idempotencyKey) {
    return { status: "invalid", message: "اختر المالك ونطاقًا زمنيًا صحيحًا للربط." };
  }
  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لربط المالك." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("assign_property_owner_v1", {
      p_organization_id: membership.organizationId,
      p_property_id: propertyId,
      p_property_owner_id: propertyOwnerId,
      p_start_date: startDate,
      p_end_date: endDate,
      p_is_primary_contact: formData.get("is_primary_contact") === "on",
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = commandError(error, "لم يعد العقار أو المالك صالحًا لهذا الربط، أو يوجد نطاق متداخل.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.property_owner.assign", error, requestId);
      return result;
    }
    revalidatePath("/workspace/properties");
    revalidatePath("/workspace/property-owners");
    return { status: "success", message: "تم ربط المالك بالعقار." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.property_owner.assign", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر ربط المالك بالعقار الآن." };
  }
}

function imageExtension(mimeType: string): string | null {
  if (mimeType === "image/jpeg") return "jpg";
  if (mimeType === "image/png") return "png";
  if (mimeType === "image/webp") return "webp";
  return null;
}

export async function uploadPropertyImageAction(
  _previousState: PropertyImageUploadState,
  formData: FormData,
): Promise<PropertyImageUploadState> {
  const propertyId = formValue(formData, "property_id");
  const idempotencyKey = formValue(formData, "idempotency_key");
  const file = formData.get("file");
  if (!propertyId || !idempotencyKey || !(file instanceof File) || file.size < 1 || file.size > 10 * 1024 * 1024) {
    return { status: "invalid", message: "اختر صورة JPEG أو PNG أو WebP بحجم لا يتجاوز 10MB." };
  }
  const imageFile = file;
  const mimeType = imageFile.type;
  const extension = imageExtension(mimeType);
  if (!extension) return { status: "invalid", message: "اختر صورة JPEG أو PNG أو WebP بحجم لا يتجاوز 10MB." };
  const requestId = randomUUID();
  let storagePath: string | null = null;
  let storageClient: ReturnType<typeof createServiceRoleSupabaseClient> | null = null;
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager", "operations"].includes(membership.role)) return { status: "denied", message: "رفع الصور متاح لمدير المخزون فقط." };
    storagePath = `${membership.organizationId}/${propertyId}/${randomUUID()}.${extension}`;
    storageClient = createServiceRoleSupabaseClient();
    const storageResult = await storageClient.storage.from("property-images").upload(storagePath, imageFile, { contentType: mimeType, upsert: false });
    if (storageResult.error) {
      reportWorkspaceActionFailure("workspace.property.image.upload", storageResult.error, requestId);
      return { status: "retry", message: "التخزين الخاص غير مهيأ أو تعذر رفع الصورة الآن." };
    }

    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("register_property_image_v1", {
      p_organization_id: membership.organizationId,
      p_property_id: propertyId,
      p_storage_path: storagePath,
      p_mime_type: mimeType,
      p_byte_size: file.size,
      p_width_px: null,
      p_height_px: null,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      await storageClient.storage.from("property-images").remove([storagePath]);
      if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية رفع صورة لهذا العقار." };
      if (["22023", "23503", "23505"].includes(error.code ?? "")) return { status: "invalid", message: "الصورة أو العقار لم يعد صالحًا للحفظ." };
      reportWorkspaceActionFailure("workspace.property.image.register", error, requestId);
      return { status: "retry", message: "تعذر تسجيل الصورة بعد رفعها. حاول مرة أخرى." };
    }
    revalidatePath("/workspace/properties");
    return { status: "success", message: "تم حفظ الصورة في التخزين الخاص." };
  } catch (error) {
    if (storageClient && storagePath) await storageClient.storage.from("property-images").remove([storagePath]).catch(() => undefined);
    reportWorkspaceActionFailure("workspace.property.image.upload", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "التخزين الخاص غير مهيأ في هذه البيئة." };
    return { status: "retry", message: "تعذر رفع الصورة الآن. حاول مرة أخرى." };
  }
}
