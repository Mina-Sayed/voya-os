"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { parseIsoDateTime } from "@/domain/time/iso-datetime";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { CrmCommandState } from "@/features/crm/crm-command-state";
import { readOrganizationTimezone } from "@/lib/organizations/organization-timezone";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

const commandRoles = new Set(["owner", "manager", "sales_agent", "operations"]);
const leadStatuses = new Set(["new", "contacted", "qualified", "offered", "won", "lost"]);
const activityTypes = new Set(["call", "whatsapp", "email", "note", "status_change", "property_offered", "booking_created"]);

const value = (formData: FormData, key: string): string | null => {
  const raw = formData.get(key);
  return typeof raw === "string" ? raw.trim() || null : null;
};

const integerValue = (formData: FormData, key: string): number | null | "invalid" => {
  const raw = value(formData, key);
  if (raw === null) return null;
  if (!/^\d+$/u.test(raw)) return "invalid";
  const parsed = Number(raw);
  return Number.isSafeInteger(parsed) ? parsed : "invalid";
};

const dateValue = (formData: FormData, key: string): string | null | "invalid" => {
  const raw = value(formData, key);
  if (raw === null) return null;
  return /^\d{4}-\d{2}-\d{2}$/u.test(raw) ? raw : "invalid";
};

function parseNextFollowUp(formData: FormData, timeZone: string): string | null | "invalid" {
  const raw = value(formData, "next_follow_up_at");
  if (!raw) return null;
  return parseIsoDateTime(raw, timeZone) ?? "invalid";
}

type LeadFields = Readonly<{
  name: string;
  phone: string | null;
  whatsapp: string | null;
  email: string | null;
  source: string;
  status: string;
  assignedMembershipId: string | null;
  requestedArea: string | null;
  checkIn: string | null;
  checkOut: string | null;
  guests: number | null;
  bedrooms: number | null;
  budgetText: string | null;
  notes: string | null;
  nextFollowUpAt: string | null;
}>;

function parseLeadFields(formData: FormData, timeZone: string): LeadFields | null {
  const name = value(formData, "name") ?? value(formData, "title");
  const phone = value(formData, "phone");
  const whatsapp = value(formData, "whatsapp");
  const email = value(formData, "email");
  const source = value(formData, "source");
  const status = value(formData, "status") ?? "new";
  const assignedMembershipId = value(formData, "assigned_membership_id");
  const requestedArea = value(formData, "requested_area");
  const checkIn = dateValue(formData, "requested_check_in");
  const checkOut = dateValue(formData, "requested_check_out");
  const guests = integerValue(formData, "guests");
  const bedrooms = integerValue(formData, "bedrooms");
  const nextFollowUpAt = parseNextFollowUp(formData, timeZone);

  if (
    !name ||
    name.length > 160 ||
    (!phone && !whatsapp && !email) ||
    !source ||
    !/^[a-z][a-z0-9_-]{0,63}$/u.test(source) ||
    !leadStatuses.has(status) ||
    checkIn === "invalid" ||
    checkOut === "invalid" ||
    (checkIn !== null && checkOut !== null && checkIn >= checkOut) ||
    (checkIn === null) !== (checkOut === null) ||
    guests === "invalid" ||
    bedrooms === "invalid" ||
    (guests !== null && (guests < 1 || guests > 50)) ||
    (bedrooms !== null && (bedrooms < 0 || bedrooms > 100)) ||
    nextFollowUpAt === "invalid"
  ) return null;

  return {
    name,
    phone,
    whatsapp,
    email,
    source,
    status,
    assignedMembershipId,
    requestedArea,
    checkIn,
    checkOut,
    guests,
    bedrooms,
    budgetText: value(formData, "budget_text"),
    notes: value(formData, "notes"),
    nextFollowUpAt,
  };
}

function invalid(message: string): CrmCommandState {
  return { status: "invalid", message };
}

function denied(message: string): CrmCommandState {
  return { status: "denied", message };
}

function commandError(error: { code?: string }, invalidMessage: string, deniedMessage: string): CrmCommandState {
  if (error.code === "42501") return denied(deniedMessage);
  if (["22023", "22001", "23503", "23505", "23514", "40001"].includes(error.code ?? "")) return invalid(invalidMessage);
  return { status: "retry", message: "تعذر حفظ بيانات CRM الآن. حاول مرة أخرى." };
}

async function loadCommandMembership() {
  const membership = await loadActionWorkspaceMembership();
  return membership && commandRoles.has(membership.role) ? membership : null;
}

async function createLegacyLeadAction(formData: FormData): Promise<CrmCommandState> {
  const title = value(formData, "title");
  const source = value(formData, "source");
  const idempotencyKey = value(formData, "idempotency_key");
  const requestedCheckIn = value(formData, "requested_check_in");
  const requestedCheckOut = value(formData, "requested_check_out");
  if (!title || !source || !idempotencyKey) return invalid("اكتب عنوان الطلب واختر مصدره.");
  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_lead", {
      p_organization_id: membership.organizationId,
      p_title: title,
      p_source: source,
      p_status: "new",
      p_requested_check_in: requestedCheckIn,
      p_requested_check_out: requestedCheckOut,
      p_assigned_membership_id: null,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      if (error.code === "42501") return denied("لا تملك صلاحية إضافة طلب.");
      if (["22023", "23503", "23514"].includes(error.code ?? "")) return invalid("تحقق من البيانات والتواريخ.");
      reportWorkspaceActionFailure("workspace.lead.create", error, requestId);
      return { status: "retry", message: "تعذر حفظ الطلب الآن. حاول مرة أخرى." };
    }
    revalidatePath("/workspace/leads");
    return { status: "success", message: "تمت إضافة الطلب." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.lead.create", error, requestId);
    return { status: "retry", message: "تعذر حفظ الطلب الآن. حاول مرة أخرى." };
  }
}

export async function createLeadAction(_previousState: CrmCommandState, formData: FormData): Promise<CrmCommandState> {
  if (formData.has("title") && !formData.has("name")) return createLegacyLeadAction(formData);
  const idempotencyKey = value(formData, "idempotency_key");
  const syntacticFields = parseLeadFields(formData, "UTC");
  if (!syntacticFields || !idempotencyKey) return invalid("أكمل الاسم ووسيلة اتصال واحدة وبيانات الطلب بصيغة صحيحة.");
  const requestId = randomUUID();

  try {
    const membership = await loadCommandMembership();
    if (!membership) return denied("لا تملك صلاحية إضافة طلب CRM.");
    const client = await createServerSupabaseClient();
    const organizationTimezone = await readOrganizationTimezone(client, membership.organizationId);
    if (!organizationTimezone) {
      reportWorkspaceActionFailure("workspace.lead.organization_timezone", new Error("Organization timezone is unavailable."), requestId);
      return { status: "retry", message: "تعذر تحديد المنطقة الزمنية للمؤسسة." };
    }
    const fields = parseLeadFields(formData, organizationTimezone);
    if (!fields) return invalid("أكمل الاسم ووسيلة اتصال واحدة وبيانات الطلب بصيغة صحيحة.");
    const { error } = await client.rpc("create_lead_v1", {
      p_organization_id: membership.organizationId,
      p_name: fields.name,
      p_phone: fields.phone,
      p_whatsapp: fields.whatsapp,
      p_email: fields.email,
      p_source: fields.source,
      p_status: fields.status,
      p_assigned_membership_id: fields.assignedMembershipId,
      p_requested_area: fields.requestedArea,
      p_check_in: fields.checkIn,
      p_check_out: fields.checkOut,
      p_guests: fields.guests,
      p_bedrooms: fields.bedrooms,
      p_budget_text: fields.budgetText,
      p_notes: fields.notes,
      p_next_follow_up_at: fields.nextFollowUpAt,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = commandError(error, "تحقق من بيانات الطلب أو مفتاح المحاولة.", "لا تملك صلاحية إضافة طلب CRM.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.lead.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/leads");
    return { status: "success", message: "تمت إضافة طلب CRM." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.lead.create", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر حفظ طلب CRM الآن. حاول مرة أخرى." };
  }
}

export async function updateLeadAction(_previousState: CrmCommandState, formData: FormData): Promise<CrmCommandState> {
  const leadId = value(formData, "lead_id");
  const idempotencyKey = value(formData, "idempotency_key");
  const expectedVersionRaw = value(formData, "expected_version");
  const expectedVersion = expectedVersionRaw && /^\d+$/u.test(expectedVersionRaw) ? Number(expectedVersionRaw) : null;
  const syntacticFields = parseLeadFields(formData, "UTC");
  if (!syntacticFields || !leadId || !idempotencyKey || !expectedVersion || !Number.isSafeInteger(expectedVersion)) return invalid("أكمل بيانات الطلب قبل الحفظ.");
  const requestId = randomUUID();

  try {
    const membership = await loadCommandMembership();
    if (!membership) return denied("لا تملك صلاحية تعديل طلب CRM.");
    const client = await createServerSupabaseClient();
    const organizationTimezone = await readOrganizationTimezone(client, membership.organizationId);
    if (!organizationTimezone) {
      reportWorkspaceActionFailure("workspace.lead.organization_timezone", new Error("Organization timezone is unavailable."), requestId);
      return { status: "retry", message: "تعذر تحديد المنطقة الزمنية للمؤسسة." };
    }
    const fields = parseLeadFields(formData, organizationTimezone);
    if (!fields) return invalid("أكمل بيانات الطلب قبل الحفظ.");
    const { error } = await client.rpc("update_lead_v1", {
      p_organization_id: membership.organizationId,
      p_lead_id: leadId,
      p_name: fields.name,
      p_phone: fields.phone,
      p_whatsapp: fields.whatsapp,
      p_email: fields.email,
      p_source: fields.source,
      p_status: fields.status,
      p_assigned_membership_id: fields.assignedMembershipId,
      p_requested_area: fields.requestedArea,
      p_check_in: fields.checkIn,
      p_check_out: fields.checkOut,
      p_guests: fields.guests,
      p_bedrooms: fields.bedrooms,
      p_budget_text: fields.budgetText,
      p_notes: fields.notes,
      p_next_follow_up_at: fields.nextFollowUpAt,
      p_expected_version: expectedVersion,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = commandError(error, "تغير الطلب أو أصبح مفتاح النسخة قديمًا. أعد تحميل الصفحة.", "لا تملك صلاحية تعديل طلب CRM.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.lead.update", error, requestId);
      return result;
    }
    revalidatePath("/workspace/leads");
    return { status: "success", message: "تم تحديث الطلب." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.lead.update", error, requestId);
    return { status: "retry", message: "تعذر تحديث الطلب الآن." };
  }
}

export async function archiveLeadAction(_previousState: CrmCommandState, formData: FormData): Promise<CrmCommandState> {
  const leadId = value(formData, "lead_id");
  const reason = value(formData, "reason");
  const idempotencyKey = value(formData, "idempotency_key");
  const expectedVersionRaw = value(formData, "expected_version");
  const expectedVersion = expectedVersionRaw && /^\d+$/u.test(expectedVersionRaw) ? Number(expectedVersionRaw) : null;
  if (!leadId || !reason || !idempotencyKey || !expectedVersion) return invalid("اكتب سبب الأرشفة وأكمل بيانات الطلب.");
  const requestId = randomUUID();
  try {
    const membership = await loadCommandMembership();
    if (!membership) return denied("لا تملك صلاحية أرشفة طلب CRM.");
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("archive_lead_v1", {
      p_organization_id: membership.organizationId,
      p_lead_id: leadId,
      p_reason: reason,
      p_expected_version: expectedVersion,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = commandError(error, "تغير الطلب أو لم تعد الأرشفة صالحة.", "لا تملك صلاحية أرشفة طلب CRM.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.lead.archive", error, requestId);
      return result;
    }
    revalidatePath("/workspace/leads");
    return { status: "success", message: "تمت أرشفة الطلب." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.lead.archive", error, requestId);
    return { status: "retry", message: "تعذر أرشفة الطلب الآن." };
  }
}

export async function createLeadActivityAction(_previousState: CrmCommandState, formData: FormData): Promise<CrmCommandState> {
  const leadId = value(formData, "lead_id");
  const activityType = value(formData, "activity_type");
  const content = value(formData, "content");
  const idempotencyKey = value(formData, "idempotency_key");
  if (!leadId || !activityType || !activityTypes.has(activityType) || !content || !idempotencyKey) return invalid("اختر نوع النشاط واكتب ملاحظته.");
  const requestId = randomUUID();
  try {
    const membership = await loadCommandMembership();
    if (!membership) return denied("لا تملك صلاحية إضافة نشاط CRM.");
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_lead_activity_v1", {
      p_organization_id: membership.organizationId,
      p_lead_id: leadId,
      p_activity_type: activityType,
      p_content: content,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = commandError(error, "تحقق من نوع النشاط ومحتواه.", "لا تملك صلاحية إضافة نشاط CRM.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.lead.activity.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/leads");
    return { status: "success", message: "تمت إضافة النشاط إلى السجل." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.lead.activity.create", error, requestId);
    return { status: "retry", message: "تعذر إضافة النشاط الآن." };
  }
}

export async function createLeadFollowUpAction(_previousState: CrmCommandState, formData: FormData): Promise<CrmCommandState> {
  const leadId = value(formData, "lead_id");
  const dueAtRaw = value(formData, "due_at");
  const note = value(formData, "note");
  const idempotencyKey = value(formData, "idempotency_key");
  const syntacticDueAt = dueAtRaw ? parseIsoDateTime(dueAtRaw, "UTC") : null;
  if (!leadId || !dueAtRaw || !syntacticDueAt || !note || !idempotencyKey) return invalid("اختر موعد المتابعة واكتب المطلوب تنفيذه.");
  const requestId = randomUUID();
  try {
    const membership = await loadCommandMembership();
    if (!membership) return denied("لا تملك صلاحية إنشاء متابعة CRM.");
    const client = await createServerSupabaseClient();
    const organizationTimezone = await readOrganizationTimezone(client, membership.organizationId);
    const dueAt = organizationTimezone ? parseIsoDateTime(dueAtRaw, organizationTimezone) : null;
    if (!dueAt) {
      if (!organizationTimezone) reportWorkspaceActionFailure("workspace.lead.organization_timezone", new Error("Organization timezone is unavailable."), requestId);
      return { status: "invalid", message: organizationTimezone ? "تحقق من موعد ومحتوى المتابعة." : "تعذر تحديد المنطقة الزمنية للمؤسسة." };
    }
    const { error } = await client.rpc("create_lead_follow_up_v1", {
      p_organization_id: membership.organizationId,
      p_lead_id: leadId,
      p_due_at: dueAt,
      p_note: note,
      p_assigned_membership_id: value(formData, "assigned_membership_id"),
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = commandError(error, "تحقق من موعد ومحتوى المتابعة.", "لا تملك صلاحية إنشاء متابعة CRM.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.lead.follow_up.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/leads");
    return { status: "success", message: "تمت جدولة المتابعة." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.lead.follow_up.create", error, requestId);
    return { status: "retry", message: "تعذر جدولة المتابعة الآن." };
  }
}

export async function completeLeadFollowUpAction(_previousState: CrmCommandState, formData: FormData): Promise<CrmCommandState> {
  const followUpId = value(formData, "follow_up_id");
  const idempotencyKey = value(formData, "idempotency_key");
  if (!followUpId || !idempotencyKey) return invalid("بيانات إكمال المتابعة غير مكتملة.");
  const requestId = randomUUID();
  try {
    const membership = await loadCommandMembership();
    if (!membership) return denied("لا تملك صلاحية إكمال متابعة CRM.");
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("complete_lead_follow_up_v1", {
      p_organization_id: membership.organizationId,
      p_follow_up_id: followUpId,
      p_note: value(formData, "completion_note"),
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = commandError(error, "المتابعة غير معلقة أو تغيرت بياناتها.", "لا تملك صلاحية إكمال متابعة CRM.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.lead.follow_up.complete", error, requestId);
      return result;
    }
    revalidatePath("/workspace/leads");
    return { status: "success", message: "تم تعليم المتابعة كمكتملة." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.lead.follow_up.complete", error, requestId);
    return { status: "retry", message: "تعذر إكمال المتابعة الآن." };
  }
}

export async function convertLeadToClientAction(_previousState: CrmCommandState, formData: FormData): Promise<CrmCommandState> {
  const leadId = value(formData, "lead_id");
  const idempotencyKey = value(formData, "idempotency_key");
  if (!leadId || !idempotencyKey) return invalid("بيانات تحويل الطلب إلى عميل غير مكتملة.");
  const requestId = randomUUID();
  try {
    const membership = await loadCommandMembership();
    if (!membership) return denied("لا تملك صلاحية تحويل الطلب إلى عميل.");
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("convert_lead_to_client_v1", {
      p_organization_id: membership.organizationId,
      p_lead_id: leadId,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = commandError(error, "لا يمكن تحويل هذا الطلب الآن؛ تحقق من حالته.", "لا تملك صلاحية تحويل الطلب إلى عميل.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.lead.convert", error, requestId);
      return result;
    }
    revalidatePath("/workspace/leads");
    revalidatePath("/workspace/clients");
    revalidatePath("/workspace/bookings");
    return { status: "success", message: "تم تحويل الطلب إلى عميل مع حفظ سجل التحويل." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.lead.convert", error, requestId);
    return { status: "retry", message: "تعذر تحويل الطلب الآن." };
  }
}
