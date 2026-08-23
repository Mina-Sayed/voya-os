"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import {
  mergeDataEntryApplicationResults,
  parseDataEntryApplicationResult,
  successfulClientIndexes,
  successfulImageKeys,
  successfulPropertyIndexes,
  terminalDataEntryApplicationResult,
  type DataEntryApplicationResult,
} from "@/domain/ai/data-entry-application";
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

type DraftDetailRow = Readonly<{
  id: string;
  status: string;
  version: number;
  expires_at: string;
  application_result?: unknown;
}>;

type InputRow = Readonly<{
  id: string;
  storage_bucket: string;
  storage_path: string;
  mime_type: "image/jpeg" | "image/png" | "image/webp";
  byte_size: number;
  status: "active" | "mapped" | "archived";
  mapped_property_id: string | null;
}>;

type ClaimRow = Readonly<{
  outcome: "claimed" | "in_progress" | "applied" | "expired";
  execution_token: string | null;
  draft_version: number;
  application_result: unknown;
}>;

function expectedVersionValue(formData: FormData): number | null {
  const raw = value(formData, "expected_version");
  if (!/^\d+$/u.test(raw)) return null;
  const parsed = Number(raw);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function selectedIndexes(formData: FormData, key: string, length: number): ReadonlySet<number> | null {
  const raw = value(formData, key);
  if (!raw) return new Set(Array.from({ length }, (_, index) => index));
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.some((item) => typeof item !== "number" || !Number.isSafeInteger(item) || item < 0 || item >= length)) return null;
    return new Set(parsed as number[]);
  } catch {
    return null;
  }
}

function excludedIndexes(included: ReadonlySet<number>, length: number): number[] {
  return Array.from({ length }, (_, index) => index).filter((index) => !included.has(index));
}

function mutableApplicationResult(): {
  clients: Array<{ index: number; recordId?: string; errorCode?: string }>;
  properties: Array<{ index: number; recordId?: string; errorCode?: string }>;
  images: Array<{ propertyIndex: number; inputId: string; recordId?: string; errorCode?: string }>;
} {
  return { clients: [], properties: [], images: [] };
}

function isPropertyCommandRole(role: string): boolean {
  return role === "owner" || role === "manager" || role === "operations";
}

function imageExtension(mimeType: InputRow["mime_type"]): string {
  return mimeType === "image/jpeg" ? "jpg" : mimeType === "image/png" ? "png" : "webp";
}

function isDefinitiveImageRegistrationFailure(error: { code?: string } | null | undefined): boolean {
  return ["22023", "22001", "23503", "23505", "23514", "40001", "42501"].includes(error?.code ?? "");
}

function resultIds(result: DataEntryApplicationResult) {
  return {
    clientIds: result.clients.flatMap((item) => item.recordId && item.recordId !== "already_mapped" ? [item.recordId] : []),
    propertyIds: result.properties.flatMap((item) => item.recordId && item.recordId !== "already_mapped" ? [item.recordId] : []),
  };
}

export async function createAiDataEntryDraftAction(
  _previousState: DataEntryActionState,
  formData: FormData,
): Promise<DataEntryActionState> {
  const sourceText = value(formData, "source_text");
  const idempotencyKey = value(formData, "idempotency_key");
  if (sourceText.length > 20_000 || !idempotencyKey || idempotencyKey.length > 160) return invalid("اكتب بيانات قبل بدء الاستخراج.");
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
      revalidatePath("/workspace/ai");
      return invalid("انتهت صلاحية المسودة أو لم تعد قابلة للإرسال. جهّز مسودة جديدة.");
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
    try {
      parsedPayload = JSON.parse(payloadText) as unknown;
    } catch {
      return invalid("صيغة المسودة غير صالحة.");
    }
    const parsed = parseEditableDataEntryPayload(parsedPayload, inputs.map((input) => input.id));
    if (!parsed.ok) return invalid("أكمل الحقول المطلوبة قبل تأكيد الحفظ.");
    const payload: DataEntryPayload = parsed.value;
    const includedClients = selectedIndexes(formData, "included_client_indexes", payload.clients.length);
    const includedProperties = selectedIndexes(formData, "included_property_indexes", payload.properties.length);
    if (!includedClients || !includedProperties) return invalid("اختيارات المراجعة غير صالحة. أعد تحميل المسودة.");

    const previous = parseDataEntryApplicationResult(draft.application_result);
    const previousTerminal = terminalDataEntryApplicationResult(previous);
    const successfulClients = successfulClientIndexes(previousTerminal);
    const successfulProperties = successfulPropertyIndexes(previousTerminal);
    const successfulImages = successfulImageKeys(previousTerminal);
    const selectedPayload: DataEntryPayload = {
      ...payload,
      clients: payload.clients.filter((_item, index) => includedClients.has(index) && !successfulClients.has(index)),
      properties: payload.properties.filter((_item, index) => includedProperties.has(index) && !successfulProperties.has(index)),
    };
    if (!canConfirmDataEntryPayload(selectedPayload)) return invalid("أكمل الحقول المطلوبة قبل تأكيد الحفظ.");
    const hasPreviousTerminal = previousTerminal.clients.length > 0 || previousTerminal.properties.length > 0 || successfulImages.size > 0;
    if (selectedPayload.clients.length === 0 && selectedPayload.properties.length === 0 && !hasPreviousTerminal) return invalid("اختر سجلًا واحدًا على الأقل للحفظ.");

    const claimResult = await client.rpc("claim_ai_data_entry_confirmation_v3", {
      p_organization_id: membership.organizationId,
      p_draft_id: draftId,
      p_confirmation_payload: payload,
      p_excluded_client_indexes: excludedIndexes(includedClients, payload.clients.length),
      p_excluded_property_indexes: excludedIndexes(includedProperties, payload.properties.length),
      p_expected_version: expectedVersion,
      p_idempotency_key: confirmationKey,
      p_request_id: requestId,
    });
    if (claimResult.error) return commandError(claimResult.error, "تغيرت المسودة أو لم تعد قابلة للتأكيد. أعد تحميلها.");
    const claim = ((claimResult.data ?? []) as ClaimRow[])[0];
    if (!claim) return { status: "retry", message: "تعذر بدء تنفيذ التأكيد الآن." };
    const claimPrevious = parseDataEntryApplicationResult(claim.application_result);

    if (claim.outcome === "expired") {
      revalidatePath("/workspace/ai");
      return invalid("انتهت صلاحية المسودة. جهّز مسودة جديدة.");
    }
    if (claim.outcome === "in_progress") return { status: "retry", message: "يجري تنفيذ هذا التأكيد بالفعل. أعد تحميل الصفحة قبل إعادة المحاولة." };
    if (claim.outcome === "applied") {
      const ids = resultIds(claimPrevious);
      return { status: "success", message: "تم حفظ البيانات المؤكدة.", ...ids };
    }
    if (claim.outcome !== "claimed" || !claim.execution_token) return { status: "retry", message: "تعذر امتلاك تنفيذ التأكيد الآن." };

    const serviceClient = createServiceRoleSupabaseClient();
    const heartbeat = async (): Promise<boolean> => {
      const beat = await serviceClient.rpc("heartbeat_ai_data_entry_confirmation_v3", {
        p_organization_id: membership.organizationId,
        p_draft_id: draftId,
        p_execution_token: claim.execution_token,
      });
      if (beat.error || beat.data !== true) {
        reportWorkspaceActionFailure("workspace.ai.data_entry.confirmation.heartbeat", beat.error ?? new Error("confirmation heartbeat failed"), requestId);
        return false;
      }
      return true;
    };

    const priorTerminal = terminalDataEntryApplicationResult(claimPrevious);
    const priorClientSuccess = successfulClientIndexes(priorTerminal);
    const priorPropertySuccess = successfulPropertyIndexes(priorTerminal);
    const priorImageSuccess = successfulImageKeys(priorTerminal);
    const current = mutableApplicationResult();
    let hasFailure = false;

    for (const [index, clientDraft] of payload.clients.entries()) {
      if (!includedClients.has(index) || priorClientSuccess.has(index)) continue;
      if (!(await heartbeat())) return { status: "retry", message: "تعذر تجديد امتلاك تنفيذ التأكيد. أعد تحميل المسودة قبل المحاولة مرة أخرى.", ...resultIds(priorTerminal) };
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
        current.clients.push({ index, errorCode: command.error?.code ?? "client_command_failed" });
      } else {
        current.clients.push({ index, recordId: command.data });
      }
    }

    for (const [index, propertyDraft] of payload.properties.entries()) {
      if (!includedProperties.has(index) || priorPropertySuccess.has(index)) continue;
      if (!isPropertyCommandRole(membership.role)) {
        hasFailure = true;
        current.properties.push({ index, errorCode: "property_write_forbidden" });
        continue;
      }
      if (!(await heartbeat())) return { status: "retry", message: "تعذر تجديد امتلاك تنفيذ التأكيد. أعد تحميل المسودة قبل المحاولة مرة أخرى.", ...resultIds(mergeDataEntryApplicationResults(priorTerminal, current)) };
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
        current.properties.push({ index, errorCode: command.error?.code ?? "property_command_failed" });
      } else {
        current.properties.push({ index, recordId: command.data });
      }
    }

    const intermediate = mergeDataEntryApplicationResults(priorTerminal, current);
    const propertyRecordIds = new Map(intermediate.properties.flatMap((item) => item.recordId ? [[item.index, item.recordId] as const] : []));

    for (const [propertyIndex, propertyDraft] of payload.properties.entries()) {
      if (!includedProperties.has(propertyIndex)) continue;
      const propertyId = propertyRecordIds.get(propertyIndex);
      if (!propertyId) continue;
      for (const inputId of propertyDraft.imageInputIds) {
        const imageKey = `${propertyIndex}:${inputId}`;
        if (priorImageSuccess.has(imageKey)) continue;
        const input = inputs.find((candidate) => candidate.id === inputId);
        if (!input || input.status === "archived") {
          hasFailure = true;
          current.images.push({ propertyIndex, inputId, errorCode: "image_input_missing" });
          continue;
        }
        if (input.status === "mapped" && input.mapped_property_id === propertyId) {
          current.images.push({ propertyIndex, inputId, recordId: "already_mapped" });
          continue;
        }
        if (!(await heartbeat())) return { status: "retry", message: "تعذر تجديد امتلاك تنفيذ التأكيد. أعد تحميل المسودة قبل المحاولة مرة أخرى.", ...resultIds(mergeDataEntryApplicationResults(priorTerminal, current)) };
        try {
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
          if (register.error || typeof register.data !== "string") {
            if (isDefinitiveImageRegistrationFailure(register.error)) {
              const rollback = await serviceClient.storage.from("property-images").remove([storagePath]);
              if (rollback.error) reportWorkspaceActionFailure("workspace.ai.data_entry.image.rollback", rollback.error, requestId);
            }
            throw new Error(register.error?.code ?? "image_register_failed");
          }
          const mapped = await serviceClient.rpc("mark_ai_data_entry_input_mapped_v2", {
            p_organization_id: membership.organizationId,
            p_input_id: inputId,
            p_property_id: propertyId,
            p_property_image_id: register.data,
            p_execution_token: claim.execution_token,
            p_request_id: requestId,
          });
          if (mapped.error || mapped.data !== true) throw new Error(mapped.error?.code ?? "image_map_failed");
          current.images.push({ propertyIndex, inputId, recordId: register.data });
        } catch (error) {
          hasFailure = true;
          const code = error instanceof Error && /^[a-z][a-z0-9_.-]{0,119}$/u.test(error.message) ? error.message : "image_command_failed";
          current.images.push({ propertyIndex, inputId, errorCode: code });
        }
      }
    }

    const applicationResult = mergeDataEntryApplicationResults(priorTerminal, current);
    const successfulAppliedInputIds = new Set(applicationResult.images.flatMap((item) => item.recordId ? [item.inputId] : []));
    const requestedInputIds = new Set(payload.properties.flatMap((property, index) => includedProperties.has(index) ? property.imageInputIds : []));
    const activeUnusedInputIds = inputs
      .filter((input) => input.status === "active" && !requestedInputIds.has(input.id) && !successfulAppliedInputIds.has(input.id))
      .map((input) => input.id);

    if (activeUnusedInputIds.length > 0) {
      if (!(await heartbeat())) return { status: "retry", message: "تعذر تجديد امتلاك تنفيذ التأكيد قبل تنظيف الملفات الخاصة.", ...resultIds(applicationResult) };
      const archived = await serviceClient.rpc("archive_ai_data_entry_inputs_v1", {
        p_organization_id: membership.organizationId,
        p_draft_id: draftId,
        p_input_ids: activeUnusedInputIds,
        p_execution_token: claim.execution_token,
      });
      if (archived.error || archived.data !== true) {
        hasFailure = true;
        reportWorkspaceActionFailure("workspace.ai.data_entry.input.archive", archived.error ?? new Error("input archive failed"), requestId);
      }
    }

    const archiveFailed = activeUnusedInputIds.length > 0 && hasFailure
      && inputs.some((input) => activeUnusedInputIds.includes(input.id));
    const cleanupInputs = inputs.filter((input) => {
      if (input.status === "active" && requestedInputIds.has(input.id) && !successfulAppliedInputIds.has(input.id)) return false;
      if (archiveFailed && input.status === "active" && activeUnusedInputIds.includes(input.id)) return false;
      return input.status === "mapped" || input.status === "archived" || successfulAppliedInputIds.has(input.id) || activeUnusedInputIds.includes(input.id);
    });
    if (cleanupInputs.length > 0) {
      const cleanup = await serviceClient.storage.from("ai-intake").remove(cleanupInputs.map((input) => input.storage_path));
      if (cleanup.error) {
        hasFailure = true;
        reportWorkspaceActionFailure("workspace.ai.data_entry.input.cleanup", cleanup.error, requestId);
      }
    }

    if (!(await heartbeat())) return { status: "retry", message: "تعذر تجديد امتلاك تنفيذ التأكيد قبل تسجيل النتيجة. أعد تحميل المسودة قبل المحاولة مرة أخرى.", ...resultIds(applicationResult) };

    const finalStatus = hasFailure ? "partially_applied" : "applied";
    const progress = await serviceClient.rpc("finalize_ai_data_entry_confirmation_v2", {
      p_organization_id: membership.organizationId,
      p_draft_id: draftId,
      p_execution_token: claim.execution_token,
      p_status: finalStatus,
      p_application_result: applicationResult,
      p_expected_version: claim.draft_version,
      p_request_id: requestId,
    });
    const ids = resultIds(applicationResult);
    if (progress.error || progress.data !== true) {
      reportWorkspaceActionFailure("workspace.ai.data_entry.progress", progress.error ?? new Error("trusted finalization failed"), requestId);
      return { status: "retry", message: "تم تنفيذ بعض الأوامر لكن تعذر تسجيل حالة المسودة. راجع السجل قبل إعادة المحاولة.", ...ids };
    }
    revalidatePath("/workspace/ai");
    revalidatePath("/workspace/clients");
    revalidatePath("/workspace/properties");
    return hasFailure
      ? { status: "retry", message: "تم حفظ جزء من البيانات. راجع الأخطاء وأعد محاولة المسودة لاستكمال الباقي.", ...ids }
      : { status: "success", message: "تم حفظ البيانات المؤكدة.", ...ids };
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
    const { error } = await client.rpc("reject_ai_data_entry_draft_v1", {
      p_organization_id: membership.organizationId,
      p_draft_id: draftId,
      p_expected_version: expectedVersion,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) return commandError(error, "تغيرت المسودة أو لم تعد قابلة للإلغاء.");

    let cleanupFailed = false;
    try {
      const serviceClient = createServiceRoleSupabaseClient();
      const paths = ((inputsResult.data ?? []) as InputRow[]).filter((input) => input.status !== "mapped").map((input) => input.storage_path);
      if (paths.length > 0) {
        const cleanup = await serviceClient.storage.from("ai-intake").remove(paths);
        if (cleanup.error) {
          cleanupFailed = true;
          reportWorkspaceActionFailure("workspace.ai.data_entry.cleanup", cleanup.error, requestId);
        }
      }
    } catch (cleanupError) {
      cleanupFailed = true;
      reportWorkspaceActionFailure("workspace.ai.data_entry.cleanup", cleanupError, requestId);
    }
    revalidatePath("/workspace/ai");
    return cleanupFailed
      ? { status: "success", message: "تم إلغاء المسودة، لكن تعذر تنظيف بعض الملفات الخاصة تلقائيًا وتم تسجيل المشكلة للمتابعة." }
      : { status: "success", message: "تم إلغاء المسودة وتنظيف الملفات الخاصة." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.ai.data_entry.reject", error, requestId);
    return { status: "retry", message: "تعذر إلغاء المسودة الآن." };
  }
}
