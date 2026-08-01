"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { LeadCreateState } from "@/features/leads/lead-create-form";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

const value = (formData: FormData, key: string) => {
  const raw = formData.get(key);
  return typeof raw === "string" ? raw.trim() : null;
};

export async function createLeadAction(
  _previousState: LeadCreateState,
  formData: FormData,
): Promise<LeadCreateState> {
  const title = value(formData, "title");
  const source = value(formData, "source");
  const idempotencyKey = value(formData, "idempotency_key");
  const requestedCheckIn = value(formData, "requested_check_in") || null;
  const requestedCheckOut = value(formData, "requested_check_out") || null;
  if (!title || !source || !idempotencyKey) {
    return { status: "invalid", message: "اكتب عنوان الطلب واختر مصدره." };
  }

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
      if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إضافة طلب." };
      if (["22023", "23503", "23514"].includes(error.code ?? "")) {
        return { status: "invalid", message: "تحقق من البيانات والتواريخ." };
      }
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
