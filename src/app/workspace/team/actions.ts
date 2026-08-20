"use server";

import { randomBytes, randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { isValidEmailAddress, normalizeEmailAddress } from "@/features/auth/email-address";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { TeamActionState } from "@/features/team/team-page";
import { sealOutboxPayload } from "@/lib/outbox/sealed-payload";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

const teamRoles = new Set(["owner", "manager", "operator", "viewer"]);

function formValue(formData: FormData, key: string): string {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function mapTeamError(
  operation: string,
  error: { code?: string; message?: string },
  requestId: ReturnType<typeof randomUUID>,
  retryMessage = "تعذر تنفيذ إجراء الفريق الآن. حاول مرة أخرى.",
): TeamActionState {
  if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إدارة الفريق." };
  if (["22023", "23503", "23505"].includes(error.code ?? "")) {
    return { status: "invalid", message: "لم يعد إجراء الفريق صالحًا أو أن البيانات مكررة." };
  }
  reportWorkspaceActionFailure(operation, error, requestId);
  return { status: "retry", message: retryMessage };
}

export async function inviteTeamMemberAction(
  _previousState: TeamActionState,
  formData: FormData,
): Promise<TeamActionState> {
  const email = normalizeEmailAddress(formValue(formData, "email"));
  const role = formValue(formData, "role").toLowerCase();
  if (!isValidEmailAddress(email) || !teamRoles.has(role)) {
    return { status: "invalid", message: "اكتب بريدًا صحيحًا واختر دورًا صالحًا." };
  }

  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لإدارة الفريق." };
    if (membership.role !== "owner") return { status: "denied", message: "دعوات الفريق متاحة لمالك المؤسسة فقط." };

    const oneTimeToken = randomBytes(32).toString("hex");
    const encryptionKey = process.env.OUTBOX_PAYLOAD_ENCRYPTION_KEY?.trim();
    if (!encryptionKey) return { status: "retry", message: "الخدمة غير مهيأة لإرسال دعوات الفريق." };
    const sealedToken = sealOutboxPayload(oneTimeToken, encryptionKey);
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("invite_organization_member_v1", {
      p_organization_id: membership.organizationId,
      p_email: email,
      p_role: role,
      p_token_digest: oneTimeToken,
      p_sealed_token: sealedToken,
      p_request_id: requestId,
    });
    if (error) return mapTeamError("workspace.team.invite", error, requestId, "تعذر إنشاء الدعوة الآن. حاول مرة أخرى.");

    revalidatePath("/workspace/team");
    return { status: "success", message: "تم إنشاء الدعوة وستُرسل عبر قناة البريد المعتمدة." };
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    reportWorkspaceActionFailure("workspace.team.invite", error, requestId);
    return { status: "retry", message: "تعذر إنشاء الدعوة الآن. حاول مرة أخرى." };
  }
}

type TeamCommand =
  | "change_role"
  | "suspend"
  | "reactivate"
  | "remove"
  | "revoke_invitation"
  | "resend_invitation";

function isTeamCommand(value: string): value is TeamCommand {
  return ["change_role", "suspend", "reactivate", "remove", "revoke_invitation", "resend_invitation"].includes(value);
}

export async function teamMemberCommandAction(
  _previousState: TeamActionState,
  formData: FormData,
): Promise<TeamActionState> {
  const command = formValue(formData, "command");
  const membershipId = formValue(formData, "membership_id");
  const invitationId = formValue(formData, "invitation_id");
  const role = formValue(formData, "role").toLowerCase();
  const reason = formValue(formData, "reason");

  if (!isTeamCommand(command)) return { status: "invalid", message: "إجراء الفريق غير صالح." };
  if (["change_role", "suspend", "reactivate", "remove"].includes(command) && !membershipId) {
    return { status: "invalid", message: "تعذر تحديد عضو الفريق." };
  }
  if (["revoke_invitation", "resend_invitation"].includes(command) && !invitationId) {
    return { status: "invalid", message: "تعذر تحديد الدعوة." };
  }
  if (command === "change_role" && !teamRoles.has(role)) {
    return { status: "invalid", message: "دور الفريق غير صالح." };
  }
  if (["suspend", "remove"].includes(command) && !reason) {
    return { status: "invalid", message: "اكتب سبب الإجراء قبل الحفظ." };
  }

  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لإدارة الفريق." };
    if (membership.role !== "owner") return { status: "denied", message: "إجراءات الفريق متاحة لمالك المؤسسة فقط." };

    const rpcByCommand: Record<TeamCommand, string> = {
      change_role: "change_organization_member_role",
      suspend: "suspend_organization_member",
      reactivate: "reactivate_organization_member",
      remove: "remove_organization_member",
      revoke_invitation: "revoke_organization_invitation",
      resend_invitation: "resend_organization_invitation_v1",
    };
    const parameters: Record<string, string> = {
      p_organization_id: membership.organizationId,
      p_request_id: requestId,
    };
    if (membershipId) parameters.p_membership_id = membershipId;
    if (invitationId) parameters.p_invitation_id = invitationId;
    if (command === "change_role") parameters.p_role = role;
    if (command === "suspend" || command === "remove") parameters.p_reason = reason;
    if (command === "resend_invitation") {
      const encryptionKey = process.env.OUTBOX_PAYLOAD_ENCRYPTION_KEY?.trim();
      if (!encryptionKey) return { status: "retry", message: "الخدمة غير مهيأة لإرسال دعوات الفريق." };
      const oneTimeToken = randomBytes(32).toString("hex");
      parameters.p_token_digest = oneTimeToken;
      parameters.p_sealed_token = sealOutboxPayload(oneTimeToken, encryptionKey);
    }

    const client = await createServerSupabaseClient();
    const { error } = await client.rpc(rpcByCommand[command], parameters);
    if (error) return mapTeamError(`workspace.team.${command}`, error, requestId);

    revalidatePath("/workspace/team");
    const messages: Record<TeamCommand, string> = {
      change_role: "تم تحديث دور العضو.",
      suspend: "تم تعليق العضو.",
      reactivate: "تمت إعادة تفعيل العضو.",
      remove: "تمت إزالة العضو.",
      revoke_invitation: "تم إلغاء الدعوة.",
      resend_invitation: "تمت جدولة إعادة إرسال الدعوة.",
    };
    return { status: "success", message: messages[command] };
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    reportWorkspaceActionFailure(`workspace.team.${command}`, error, requestId);
    return { status: "retry", message: "تعذر تنفيذ إجراء الفريق الآن. حاول مرة أخرى." };
  }
}
