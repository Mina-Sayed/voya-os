"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { isValidInvitationToken } from "@/features/auth/invitation-token";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

export type InvitationActionState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
}>;

export async function acceptOrganizationInvitationAction(
  _previousState: InvitationActionState,
  formData: FormData,
): Promise<InvitationActionState> {
  const token = String(formData.get("token") ?? "").trim().toLowerCase();
  if (!isValidInvitationToken(token)) return { status: "invalid", message: "رابط الدعوة غير صالح." };

  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) {
      const client = await createServerSupabaseClient();
      const { data } = await client.auth.getUser();
      if (!data.user) return { status: "denied", message: "سجّل الدخول بالبريد المرتبط بالدعوة أولًا." };
    }

    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("accept_organization_invitation", {
      p_token_digest: token,
      p_request_id: requestId,
    });
    if (error) {
      if (["22023", "23503", "42501"].includes(error.code ?? "")) {
        return { status: "invalid", message: "الدعوة غير صالحة أو منتهية أو مرتبطة ببريد مختلف." };
      }
      reportWorkspaceActionFailure("workspace.team.invitation.accept", error, requestId);
      return { status: "retry", message: "تعذر قبول الدعوة الآن. حاول مرة أخرى." };
    }

    revalidatePath("/workspace");
    revalidatePath("/workspace/team");
    return { status: "success", message: "تم قبول الدعوة. جارٍ فتح مساحة العمل…" };
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    reportWorkspaceActionFailure("workspace.team.invitation.accept", error, requestId);
    return { status: "retry", message: "تعذر قبول الدعوة الآن. حاول مرة أخرى." };
  }
}
