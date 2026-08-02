"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { AiActionState } from "@/features/ai/agent-center-page";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

const value = (formData: FormData, key: string) => {
  const raw = formData.get(key);
  return typeof raw === "string" ? raw.trim() : null;
};

export async function createAiRunRequestAction(
  _previousState: AiActionState,
  formData: FormData,
): Promise<AiActionState> {
  const agentKind = value(formData, "agent_kind");
  const purpose = value(formData, "purpose");
  const idempotencyKey = value(formData, "idempotency_key");
  const requestId = randomUUID();
  if (!agentKind || !purpose || !idempotencyKey) return { status: "invalid", message: "حدد الوصلة واكتب المطلوب." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_ai_run_request", {
      p_organization_id: membership.organizationId,
      p_agent_kind: agentKind,
      p_purpose: purpose,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      if (error.code === "42501") return { status: "denied", message: "هذه الوصلة غير مفعّلة أو لا تسمح بها صلاحياتك." };
      if (["22023", "23505", "23514"].includes(error.code ?? "")) return { status: "invalid", message: "تحقق من الطلب وحاول مرة أخرى." };
      reportWorkspaceActionFailure("workspace.ai.run.request", error, requestId);
      return { status: "retry", message: "تعذر تسجيل طلب المساعدة الآن." };
    }
    revalidatePath("/workspace/ai");
    return { status: "success", message: "تم تسجيل الطلب في قائمة التشغيل. لا يوجد تنفيذ تلقائي حتى الآن." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.ai.run.request", error, requestId);
    return { status: "retry", message: "تعذر تسجيل طلب المساعدة الآن." };
  }
}
