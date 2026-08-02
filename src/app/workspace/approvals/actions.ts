"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { ApprovalActionState } from "@/features/approvals/approval-requests-page";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

export async function decideBookingApprovalAction(_previousState: ApprovalActionState, formData: FormData): Promise<ApprovalActionState> {
  const approvalId = formData.get("approval_request_id");
  const decision = formData.get("decision");
  const reason = formData.get("reason");
  const requestId = randomUUID();
  if (typeof approvalId !== "string" || typeof decision !== "string" || typeof reason !== "string" || !reason.trim()) return { status: "invalid", message: "اكتب سبب القرار قبل الحفظ." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager"].includes(membership.role)) return { status: "denied", message: "قرارات الاعتماد متاحة لمالك المؤسسة والمدير فقط." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("decide_booking_approval", { p_organization_id: membership.organizationId, p_approval_request_id: approvalId, p_decision: decision, p_reason: reason.trim(), p_request_id: requestId });
    if (error) {
      if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية اتخاذ هذا القرار." };
      if (["22023", "23503", "23505", "23514"].includes(error.code ?? "")) return { status: "invalid", message: "طلب الاعتماد لم يعد صالحاً أو القرار مكرر." };
      reportWorkspaceActionFailure("workspace.approval.booking.decide", error, requestId);
      return { status: "retry", message: "تعذر حفظ قرار الاعتماد الآن." };
    }
    revalidatePath("/workspace/approvals");
    revalidatePath("/workspace/bookings");
    return { status: "success", message: decision === "approved" ? "تم اعتماد الحجز." : "تم رفض الحجز وإعادته لمسودة." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.approval.booking.decide", error, requestId);
    return { status: "retry", message: "تعذر حفظ قرار الاعتماد الآن." };
  }
}
