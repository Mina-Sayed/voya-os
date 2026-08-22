"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { canConfirmDataEntryPayload, isDataEntryRole, type DataEntryPayload } from "@/domain/ai/data-entry-contract";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import { parseEditableDataEntryPayload } from "@/lib/ai/data-entry-payload";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServiceRoleSupabaseClient, createServerSupabaseClient } from "@/lib/supabase/server-auth";

export type DataEntryActionState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
  draftId?: string;
  runId?: string;
  clientIds?: readonly string[];
  propertyIds?: readonly string[];
}>;

const value = (formData: FormData, key: string): string => {
  const raw = formData.get(key);
  return typeof raw === "string" ? raw.trim() : "";
};

function invalid(message: string): DataEntryActionState {
  return { status: "invalid", message };
}

function denied(message: string): DataEntryActionState {
  return { status: "denied", message };
}

function commandError(error: { code?: string }, message: string): DataEntryActionState {
  if (error.code === "42501") return denied("لا تملك صلاحية تنفيذ إدخال البيانات.");
  if (["22023", "22001", "23503", "23505", "40001"].includes(error.code ?? "")) return invalid(message);
  return { status: "retry", message: "تعذر تنفيذ طلب إدخال البيانات الآن." };
}

async function loadDataEntryMembership() {
  const membership = await loadActionWorkspaceMembership();
  return membership && isDataEntryRole(membership.role) ? membership : null;
}

type DraftDetailRow = Readonly<{ id: string; status: string; version: number; expires_at: string }>;

type InputRow = Readonly<{
  id: string;
  storage_bucket: string;
  storage_path: string;
  mime_type: "image/jpeg" | "image/png" | "image/webp";
  byte_size: number;
  status: "active" | "mapped" | "archived";
  mapped_property_id: string | null;
}>;

type ApplicationResult = Readonly<{
  clients: readonly Readonly<{ index: number; recordId?: string; errorCode?: string }>[];
  properties: readonly Readonly<{ index: number; recordId?: string; errorCode?: string }>[];
  images: readonly Readonly<{ propertyIndex: number; inputId: string; recordId?: string; errorCode?: string }>[];
}>;

function expectedVersionValue(formData: FormData): number | null {
  const raw = value(formData, "expected_version");
  if (!/^\d+$/u.test(raw)) return null;
  const parsed = Number(raw);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function newApplicationResult(): { clients: Array<{ index: number; recordId?: string; errorCode?: string }>; properties: Array<{ index: number; recordId?: string; errorCode?: string }>; images: Array<{ propertyIndex: number; inputId: string; recordId?: string; errorCode?: string }> } {
  return { clients: [], properties: [], images: [] };
}

function isPropertyCommandRole(role: string): boolean {
  return role === "owner" || role === "manager" || role === "operations";
}

function imageExtension(mimeType: InputRow["mime_type"]): string {
  return mimeType === "image/jpeg" ? "jpg" : mimeType === "image/png" ? "png" : "webp";
}

export async function createAiDataEntryDraftAction(
  _previousState: DataEntryActionState,
  formData: FormData,
): Promise<DataEntryActionState> {
  const sourceText = value(formData, "source_text");
  const idempotencyKey = value(formData, "idempotency_key");
  if (!sourceText || sourceText.length > 20_000 || !idempotencyKey || idempotencyKey.length > 160) return invalid("اكتب بيانات قبل بدء الاستخراج.");
  const requestId = randomUUID();
  try {
    const membership = await loadDataEntryMembership();
    if (!membership) return denied("لا تملك صلاحية تجهيز مسودة إدخال بيانات.");
    const client = await createServerSupabaseClient();
    const { data, error } = await client.rpc("create_ai_data_entry_draft_v1", {
      p_organization_id: membership.organizationId,
      p_source_text: sourceText,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) return commandError(error, "تحقق من البيانات ومفتاح المحاولة ثم أعد المحاولة.");
    if (typeof data !== "string") {
      reportWorkspaceActionFailure("workspace.ai.data_entry.draft.create", new Error("draft id missing"), requestId);
      return { status: "retry", message: "تعذر تجهيز المسودة الآن." };
    }
    revalidatePath("/workspace/ai");
    return { status: "success", message: "تم تجهيز المسودة لرفع الصور وإرسالها للاستخراج.", draftId: data };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.ai.data_entry.draft.create", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر تجهيز المسودة الآن." };
  }
}

export async function submitAiDataEntryDraftAction(
  _previousState: DataEntryActionState,
  formData: FormData,
): Promise<DataEntryActionState> {
  const draftId = value(formData, "draft_id");
  const idempotencyKey = value(formData, "idempotency_key");
  if (!draftId || !idempotencyKey || idempotencyKey.length > 160) return invalid("اختر مسودة صالحة قبل الإرسال.");
  const requestId = randomUUID();
  try {
    const membership = await loadDataEntryMembership();
    if (!membership) return denied("لا تملك صلاحية إرسال مسودة إدخال بيانات.");
    const client = await createServerSupabaseClient();
    const { data, error } = await client.rpc("submit_ai_data_entry_draft_v1", {
      p_organization_id: membership.organizationId,
      p_draft_id: draftId,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) return commandError(error, "تحقق من المسودة ومحتواها ثم أعد المحاولة.");
    if (typeof data !== "string") {
      reportWorkspaceActionFailure("workspace.ai.data_entry.draft.submit", new Error("run id missing"), requestId);
      return { status: "retry", message: "تعذر إرسال المسودة الآن." };
    }
    revalidatePath("/workspace/ai");
    return { status: "success", message: "تم إرسال المسودة للاستخراج والمراجعة.", runId: data };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.ai.data_entry.draft.submit", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر إرسال المسودة الآن." };
  }
}

export async function confirmAiDataEntryDraftAction(
  _previousState: DataEntryActionState,
  formData: FormData,
): Promise<DataEntryActionState> {
  const draftId = value(formData, "draft_id");
  const expectedVersion = expectedVersionValue(formData);
  const confirmationKey = value(formData, "confirmation_idempotency_key");
  const payloadText = value(formData, "payload_json");
  if (!draftId || !expectedVersion || !confirmationKey || confirmationKey.length > 160 || !payloadText || payloadText.length > 20_000) return invalid("أكمل بيانات المراجعة قبل تأكيد الحفظ.");
  const requestId = randomUUID();
  try {
    const membership = await loadDataEntryMembership();
    if (!membership) return denied("لا تملك صلاحية تأكيد إدخال البيانات.");
    const client = await createServerSupabaseClient();
    const draftResult = await client.rpc("get_ai_data_entry_draft_v1", { p_organization_id: membership.organizationId, p_draft_id: draftId });
    if (draftResult.error) return commandError(draftResult.error, "تعذر قراءة المسودة. أعد تحميل الصفحة.");
    const draft = ((draftResult.data ?? []) as DraftDetailRow[])[0];
    if (!draft) return invalid("المسودة غير موجودة أو لم تعد متاحة.");
    const inputsResult = await client.rpc("list_ai_data_entry_inputs_v1", { p_organization_id: membership.organizationId, p_draft_id: draftId });
    if (inputsResult.error) return commandError(inputsResult.error, "تعذر قراءة الصور المرتبطة بالمسودة.");
    const inputs = (inputsResult.data ?? []) as InputRow[];
    let parsedPayload: unknown;
    try { parsedPayload = JSON.parse(payloadText) as unknown; } catch { return invalid("صيغة المسودة غير صالحة."); }
    const parsed = parseEditableDataEntryPayload(parsedPayload, inputs.map((input) => input.id));
    if (!parsed.ok || !canConfirmDataEntryPayload(parsed.value) || (parsed.value.clients.length === 0 && parsed.value.properties.length === 0)) return invalid("أكمل الحقول المطلوبة قبل تأكيد الحفظ.");
    const payload: DataEntryPayload = parsed.value;
    const beginResult = await client.rpc("begin_ai_data_entry_confirmation_v1", {
      p_organization_id: membership.organizationId,
      p_draft_id: draftId,
      p_confirmation_payload: payload,
      p_expected_version: expectedVersion,
      p_idempotency_key: confirmationKey,
      p_request_id: requestId,
    });
    if (beginResult.error) return commandError(beginResult.error, "تغيرت المسودة أو لم تعد قابلة للتأكيد. أعد تحميلها.");

    const confirmedDraftResult = await client.rpc("get_ai_data_entry_draft_v1", { p_organization_id: membership.organizationId, p_draft_id: draftId });
    if (confirmedDraftResult.error) return { status: "retry", message: "تم بدء التأكيد لكن تعذر متابعة الحفظ. أعد المحاولة." };
    const confirmedDraft = ((confirmedDraftResult.data ?? []) as DraftDetailRow[])[0];
    if (!confirmedDraft) return { status: "retry", message: "تعذر متابعة حفظ المسودة." };

    const result = newApplicationResult();
    let hasFailure = false;
    const clientIds: string[] = [];
    const propertyIds: string[] = [];
    for (const [index, clientDraft] of payload.clients.entries()) {
      const command = await client.rpc("create_client_v1", {
        p_organization_id: membership.organizationId,
        p_display_name: clientDraft.displayName,
        p_phone: clientDraft.phone,
        p_whatsapp: clientDraft.whatsapp,
        p_email: clientDraft.email,
        p_nationality: clientDraft.nationality,
        p_preferred_language: clientDraft.preferredLanguage,
        p_notes: clientDraft.notes,
        p_source_lead_id: clientDraft.sourceLeadId,
        p_idempotency_key: `ai-data-entry:${draftId}:client:${index}`,
        p_request_id: requestId,
      });
      if (command.error || typeof command.data !== "string") {
        hasFailure = true;
        result.clients.push({ index, errorCode: command.error?.code ?? "client_command_failed" });
      } else {
        clientIds.push(command.data);
        result.clients.push({ index, recordId: command.data });
      }
    }

    for (const [index, propertyDraft] of payload.properties.entries()) {
      if (!isPropertyCommandRole(membership.role)) {
        hasFailure = true;
        result.properties.push({ index, errorCode: "property_write_forbidden" });
        continue;
      }
      const command = await client.rpc("create_property_v1", {
        p_organization_id: membership.organizationId,
        p_code: propertyDraft.code,
        p_name: propertyDraft.name,
        p_timezone: propertyDraft.timezone,
        p_address: propertyDraft.address,
        p_city: propertyDraft.city,
        p_unit_label: propertyDraft.unitLabel,
        p_bedrooms: propertyDraft.bedrooms,
        p_max_guests: propertyDraft.maxGuests,
        p_operational_notes: propertyDraft.operationalNotes,
        p_idempotency_key: `ai-data-entry:${draftId}:property:${index}`,
        p_request_id: requestId,
      });
      if (command.error || typeof command.data !== "string") {
        hasFailure = true;
        result.properties.push({ index, errorCode: command.error?.code ?? "property_command_failed" });
      } else {
        propertyIds.push(command.data);
        result.properties.push({ index, recordId: command.data });
      }
    }

    let serviceClient: ReturnType<typeof createServiceRoleSupabaseClient> | null = null;
    for (const [propertyIndex, propertyDraft] of payload.properties.entries()) {
      const propertyId = result.properties.find((item) => item.index === propertyIndex)?.recordId;
      if (!propertyId) continue;
      for (const inputId of propertyDraft.imageInputIds) {
        const input = inputs.find((candidate) => candidate.id === inputId);
        if (!input || input.status === "archived") {
          hasFailure = true;
          result.images.push({ propertyIndex, inputId, errorCode: "image_input_missing" });
          continue;
        }
        if (input.status === "mapped" && input.mapped_property_id === propertyId) {
          result.images.push({ propertyIndex, inputId, recordId: "already_mapped" });
          continue;
        }
        try {
          serviceClient ??= createServiceRoleSupabaseClient();
          const { data: source, error: downloadError } = await serviceClient.storage.from("ai-intake").download(input.storage_path);
          if (downloadError || !source) throw new Error("image_download_failed");
          const bytes = new Uint8Array(await source.arrayBuffer());
          const storagePath = `${membership.organizationId}/${propertyId}/${input.id}.${imageExtension(input.mime_type)}`;
          const upload = await serviceClient.storage.from("property-images").upload(storagePath, bytes, { contentType: input.mime_type, upsert: true });
          if (upload.error) throw new Error("image_upload_failed");
          const register = await client.rpc("register_property_image_v1", {
            p_organization_id: membership.organizationId,
            p_property_id: propertyId,
            p_storage_path: storagePath,
            p_mime_type: input.mime_type,
            p_byte_size: bytes.byteLength,
            p_width_px: null,
            p_height_px: null,
            p_idempotency_key: `ai-data-entry:${draftId}:property:${propertyIndex}:image:${inputId}`,
            p_request_id: requestId,
          });
          if (register.error || typeof register.data !== "string") throw new Error(register.error?.code ?? "image_register_failed");
          const mapped = await client.rpc("mark_ai_data_entry_input_mapped_v1", { p_organization_id: membership.organizationId, p_input_id: inputId, p_property_id: propertyId, p_request_id: requestId });
          if (mapped.error) throw new Error(mapped.error.code ?? "image_map_failed");
          await serviceClient.storage.from("ai-intake").remove([input.storage_path]).catch(() => undefined);
          result.images.push({ propertyIndex, inputId, recordId: register.data });
        } catch (error) {
          hasFailure = true;
          const code = error instanceof Error && /^[a-z][a-z0-9_.-]{0,119}$/u.test(error.message) ? error.message : "image_command_failed";
          result.images.push({ propertyIndex, inputId, errorCode: code });
        }
      }
    }

    const progress = await client.rpc("record_ai_data_entry_progress_v1", {
      p_organization_id: membership.organizationId,
      p_draft_id: draftId,
      p_status: hasFailure ? "partially_applied" : "applied",
      p_application_result: result satisfies ApplicationResult,
      p_expected_version: confirmedDraft.version,
      p_idempotency_key: `${confirmationKey}:progress`,
      p_request_id: requestId,
    });
    if (progress.error) {
      reportWorkspaceActionFailure("workspace.ai.data_entry.progress", progress.error, requestId);
      return { status: "retry", message: "تم تنفيذ بعض الأوامر لكن تعذر تسجيل حالة المسودة. راجع السجل قبل إعادة المحاولة.", clientIds, propertyIds };
    }
    revalidatePath("/workspace/ai");
    revalidatePath("/workspace/clients");
    revalidatePath("/workspace/properties");
    return hasFailure
      ? { status: "retry", message: "تم حفظ جزء من البيانات. راجع الأخطاء وأعد محاولة المسودة لاستكمال الباقي.", clientIds, propertyIds }
      : { status: "success", message: "تم حفظ البيانات المؤكدة.", clientIds, propertyIds };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.ai.data_entry.confirm", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر تأكيد وحفظ المسودة الآن." };
  }
}

export async function rejectAiDataEntryDraftAction(
  _previousState: DataEntryActionState,
  formData: FormData,
): Promise<DataEntryActionState> {
  const draftId = value(formData, "draft_id");
  const expectedVersion = expectedVersionValue(formData);
  const idempotencyKey = value(formData, "idempotency_key");
  if (!draftId || !expectedVersion || !idempotencyKey) return invalid("لا يمكن إلغاء مسودة غير مكتملة.");
  const requestId = randomUUID();
  try {
    const membership = await loadDataEntryMembership();
    if (!membership) return denied("لا تملك صلاحية إلغاء المسودة.");
    const client = await createServerSupabaseClient();
    const inputsResult = await client.rpc("list_ai_data_entry_inputs_v1", { p_organization_id: membership.organizationId, p_draft_id: draftId });
    if (inputsResult.error) return commandError(inputsResult.error, "تعذر قراءة ملفات المسودة.");
    const { error } = await client.rpc("reject_ai_data_entry_draft_v1", { p_organization_id: membership.organizationId, p_draft_id: draftId, p_expected_version: expectedVersion, p_idempotency_key: idempotencyKey, p_request_id: requestId });
    if (error) return commandError(error, "تغيرت المسودة أو لم تعد قابلة للإلغاء.");
    try {
      const serviceClient = createServiceRoleSupabaseClient();
      const paths = ((inputsResult.data ?? []) as InputRow[]).filter((input) => input.status !== "mapped").map((input) => input.storage_path);
      if (paths.length > 0) await serviceClient.storage.from("ai-intake").remove(paths);
    } catch (cleanupError) {
      reportWorkspaceActionFailure("workspace.ai.data_entry.cleanup", cleanupError, requestId);
    }
    revalidatePath("/workspace/ai");
    return { status: "success", message: "تم إلغاء المسودة وتنظيف الملفات الخاصة." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.ai.data_entry.reject", error, requestId);
    return { status: "retry", message: "تعذر إلغاء المسودة الآن." };
  }
}
