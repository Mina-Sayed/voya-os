"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { CrmCommandState } from "@/features/crm/crm-command-state";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

const commandRoles = new Set(["owner", "manager", "sales_agent", "operations"]);

const value = (formData: FormData, key: string): string | null => {
  const raw = formData.get(key);
  return typeof raw === "string" ? raw.trim() || null : null;
};

function invalid(message: string): CrmCommandState { return { status: "invalid", message }; }
function denied(message: string): CrmCommandState { return { status: "denied", message }; }

function commandError(error: { code?: string }, invalidMessage: string, deniedMessage: string): CrmCommandState {
  if (error.code === "42501") return denied(deniedMessage);
  if (["22023", "22001", "23503", "23505", "23514", "40001"].includes(error.code ?? "")) return invalid(invalidMessage);
  return { status: "retry", message: "تعذر حفظ بيانات العميل الآن. حاول مرة أخرى." };
}
async function loadCommandMembership() {
  const membership = await loadActionWorkspaceMembership();
  return membership && commandRoles.has(membership.role) ? membership : null;
}

async function createLegacyClientAction(formData: FormData): Promise<CrmCommandState> {
  const displayName = value(formData, "display_name");
  const idempotencyKey = value(formData, "idempotency_key");
  if (!displayName || !idempotencyKey) return invalid("اكتب اسم العميل للمتابعة.");
  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return denied("لا تملك مساحة عمل نشطة لإضافة عميل.");
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_client", { p_organization_id: membership.organizationId, p_display_name: displayName, p_idempotency_key: idempotencyKey, p_request_id: requestId });
    if (error) {
      if (error.code === "42501") return denied("لا تملك صلاحية إضافة عميل.");
      if (error.code === "22023") return invalid("تحقق من اسم العميل ثم أعد المحاولة.");
      reportWorkspaceActionFailure("workspace.client.create", error, requestId);
      return { status: "retry", message: "تعذر حفظ العميل الآن. حاول مرة أخرى." };
    }
    revalidatePath("/workspace/clients");
    return { status: "success", message: "تمت إضافة العميل." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.client.create", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر حفظ العميل الآن. حاول مرة أخرى." };
  }
}

type ClientFields = Readonly<{ displayName: string; phone: string | null; whatsapp: string | null; email: string | null; nationality: string | null; preferredLanguage: string | null; notes: string | null; sourceLeadId: string | null }>;

function parseClientFields(formData: FormData): ClientFields | null {
  const displayName = value(formData, "display_name");
  if (!displayName || displayName.length > 160) return null;
  return { displayName, phone: value(formData, "phone"), whatsapp: value(formData, "whatsapp"), email: value(formData, "email"), nationality: value(formData, "nationality"), preferredLanguage: value(formData, "preferred_language"), notes: value(formData, "notes"), sourceLeadId: value(formData, "source_lead_id") };
}

export async function createClientAction(_previousState: CrmCommandState, formData: FormData): Promise<CrmCommandState> {
  if (!formData.has("phone") && !formData.has("whatsapp") && !formData.has("email") && !formData.has("nationality") && !formData.has("preferred_language") && !formData.has("notes") && !formData.has("source_lead_id")) return createLegacyClientAction(formData);
  const fields = parseClientFields(formData);
  const idempotencyKey = value(formData, "idempotency_key");
  if (!fields || !idempotencyKey) return invalid("اكتب اسم العميل بصيغة صحيحة.");
  const requestId = randomUUID();
  try {
    const membership = await loadCommandMembership();
    if (!membership) return denied("لا تملك صلاحية إضافة عميل CRM.");
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_client_v1", { p_organization_id: membership.organizationId, p_display_name: fields.displayName, p_phone: fields.phone, p_whatsapp: fields.whatsapp, p_email: fields.email, p_nationality: fields.nationality, p_preferred_language: fields.preferredLanguage, p_notes: fields.notes, p_source_lead_id: fields.sourceLeadId, p_idempotency_key: idempotencyKey, p_request_id: requestId });
    if (error) {
      const result = commandError(error, "تحقق من بيانات العميل أو مفتاح المحاولة.", "لا تملك صلاحية إضافة عميل CRM.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.client.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/clients");
    return { status: "success", message: "تمت إضافة العميل إلى CRM." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.client.create", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر حفظ بيانات العميل الآن." };
  }
}

function versionValue(formData: FormData): number | null {
  const raw = value(formData, "expected_version");
  if (!raw || !/^\d+$/u.test(raw)) return null;
  const version = Number(raw);
  return Number.isSafeInteger(version) && version > 0 ? version : null;
}

export async function updateClientAction(_previousState: CrmCommandState, formData: FormData): Promise<CrmCommandState> {
  const fields = parseClientFields(formData);
  const clientId = value(formData, "client_id");
  const expectedVersion = versionValue(formData);
  const idempotencyKey = value(formData, "idempotency_key");
  if (!fields || !clientId || !expectedVersion || !idempotencyKey) return invalid("أكمل بيانات العميل قبل الحفظ.");
  const requestId = randomUUID();
  try {
    const membership = await loadCommandMembership();
    if (!membership) return denied("لا تملك صلاحية تعديل عميل CRM.");
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("update_client_v1", { p_organization_id: membership.organizationId, p_client_id: clientId, p_display_name: fields.displayName, p_phone: fields.phone, p_whatsapp: fields.whatsapp, p_email: fields.email, p_nationality: fields.nationality, p_preferred_language: fields.preferredLanguage, p_notes: fields.notes, p_expected_version: expectedVersion, p_idempotency_key: idempotencyKey, p_request_id: requestId });
    if (error) {
      const result = commandError(error, "تغيرت بيانات العميل أو أصبحت النسخة قديمة. أعد تحميل الصفحة.", "لا تملك صلاحية تعديل عميل CRM.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.client.update", error, requestId);
      return result;
    }
    revalidatePath("/workspace/clients");
    revalidatePath("/workspace/bookings");
    return { status: "success", message: "تم تحديث بيانات العميل." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.client.update", error, requestId);
    return { status: "retry", message: "تعذر تحديث بيانات العميل الآن." };
  }
}

export async function archiveClientAction(_previousState: CrmCommandState, formData: FormData): Promise<CrmCommandState> {
  const clientId = value(formData, "client_id");
  const reason = value(formData, "reason");
  const expectedVersion = versionValue(formData);
  const idempotencyKey = value(formData, "idempotency_key");
  if (!clientId || !reason || !expectedVersion || !idempotencyKey) return invalid("اكتب سبب الأرشفة وأكمل بيانات العميل.");
  const requestId = randomUUID();
  try {
    const membership = await loadCommandMembership();
    if (!membership) return denied("لا تملك صلاحية أرشفة عميل CRM.");
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("archive_client_v1", { p_organization_id: membership.organizationId, p_client_id: clientId, p_reason: reason, p_expected_version: expectedVersion, p_idempotency_key: idempotencyKey, p_request_id: requestId });
    if (error) {
      const result = commandError(error, "تغير العميل أو لم تعد الأرشفة صالحة.", "لا تملك صلاحية أرشفة عميل CRM.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.client.archive", error, requestId);
      return result;
    }
    revalidatePath("/workspace/clients");
    return { status: "success", message: "تمت أرشفة العميل." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.client.archive", error, requestId);
    return { status: "retry", message: "تعذر أرشفة العميل الآن." };
  }
}
