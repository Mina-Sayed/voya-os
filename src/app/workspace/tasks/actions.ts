"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { TaskActionState } from "@/features/tasks/operations-tasks-page";
import { parseIsoDateTime } from "@/domain/time/iso-datetime";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

const value = (formData: FormData, key: string) => {
  const raw = formData.get(key);
  return typeof raw === "string" ? raw.trim() : null;
};

export async function createOperationsTaskAction(_previousState: TaskActionState, formData: FormData): Promise<TaskActionState> {
  const taskType = value(formData, "task_type");
  const title = value(formData, "title");
  const description = value(formData, "description") || null;
  const dueAt = value(formData, "due_at") || null;
  const assignedMembershipId = value(formData, "assigned_membership_id") || null;
  const idempotencyKey = value(formData, "idempotency_key");
  const requestId = randomUUID();
  if (!taskType || !title || !idempotencyKey) return { status: "invalid", message: "أكمل نوع المهمة والعنوان." };
  const dueAtIso = dueAt ? parseIsoDateTime(dueAt) : null;
  if (dueAt && !dueAtIso) return { status: "invalid", message: "تحقق من تاريخ استحقاق المهمة." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager", "operations"].includes(membership.role)) return { status: "denied", message: "إضافة المهام متاحة لفريق التشغيل والمدير فقط." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_operations_task", {
      p_organization_id: membership.organizationId,
      p_task_type: taskType,
      p_title: title,
      p_description: description,
      p_due_at: dueAtIso,
      p_booking_id: null,
      p_assigned_membership_id: assignedMembershipId,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إضافة مهمة." };
      if (["22023", "23503", "23505", "23514"].includes(error.code ?? "")) return { status: "invalid", message: "تحقق من بيانات المهمة." };
      reportWorkspaceActionFailure("workspace.task.create", error, requestId);
      return { status: "retry", message: "تعذر حفظ المهمة الآن." };
    }
    revalidatePath("/workspace/tasks");
    return { status: "success", message: "تمت إضافة المهمة." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.task.create", error, requestId);
    return { status: "retry", message: "تعذر حفظ المهمة الآن." };
  }
}

export async function updateOperationsTaskStatusAction(taskId: string, status: string): Promise<void> {
  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return;
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("update_operations_task_status", {
      p_organization_id: membership.organizationId,
      p_task_id: taskId,
      p_status: status,
      p_request_id: requestId,
    });
    if (error && !["42501", "22023", "23503"].includes(error.code ?? "")) reportWorkspaceActionFailure("workspace.task.status", error, requestId);
    revalidatePath("/workspace/tasks");
  } catch (error) {
    reportWorkspaceActionFailure("workspace.task.status", error, requestId);
  }
}
