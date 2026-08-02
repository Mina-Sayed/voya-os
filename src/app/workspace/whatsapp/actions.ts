"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { WhatsAppActionState } from "@/features/whatsapp/whatsapp-inbox-page";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

const value = (formData: FormData, key: string) => {
  const raw = formData.get(key);
  return typeof raw === "string" ? raw.trim() : null;
};

function mapError(error: { code?: string | null }, deniedMessage: string, invalidMessage: string): WhatsAppActionState {
  if (error.code === "42501") return { status: "denied", message: deniedMessage };
  if (["22023", "23503", "23505", "23514"].includes(error.code ?? "")) return { status: "invalid", message: invalidMessage };
  return { status: "retry", message: "تعذر حفظ التغيير الآن. حاول مرة أخرى." };
}

export async function createWhatsappChannelAction(
  _previousState: WhatsAppActionState,
  formData: FormData,
): Promise<WhatsAppActionState> {
  const provider = value(formData, "provider");
  const externalChannelId = value(formData, "external_channel_id");
  const displayName = value(formData, "display_name");
  const requestId = randomUUID();
  if (!provider || !externalChannelId || !displayName) return { status: "invalid", message: "أكمل تعريف القناة قبل الحفظ." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager"].includes(membership.role)) return { status: "denied", message: "إضافة القنوات متاحة لمالك المؤسسة والمدير فقط." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_whatsapp_channel", {
      p_organization_id: membership.organizationId,
      p_provider: provider,
      p_external_channel_id: externalChannelId,
      p_display_name: displayName,
      p_request_id: requestId,
    });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية إضافة قناة.", "تحقق من بيانات القناة أو وجود قناة مكررة.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.whatsapp.channel.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/whatsapp");
    return { status: "success", message: "تم حفظ تعريف القناة. الإرسال الخارجي ما زال متوقفاً حتى تفعيل worker موثوق." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.whatsapp.channel.create", error, requestId);
    return { status: "retry", message: "تعذر حفظ القناة الآن." };
  }
}

export async function createWhatsappMessageAction(
  _previousState: WhatsAppActionState,
  formData: FormData,
): Promise<WhatsAppActionState> {
  const conversationId = value(formData, "conversation_id");
  const bodyText = value(formData, "body_text");
  const idempotencyKey = value(formData, "idempotency_key");
  const requestId = randomUUID();
  if (!conversationId || !bodyText || !idempotencyKey) return { status: "invalid", message: "اكتب الرد قبل تسجيله." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_whatsapp_message", {
      p_organization_id: membership.organizationId,
      p_conversation_id: conversationId,
      p_body_text: bodyText,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية الرد على هذه المحادثة.", "تحقق من المحادثة أو نص الرد.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.whatsapp.message.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/whatsapp");
    return { status: "success", message: "تم تسجيل الرد في قائمة الإرسال؛ لم يتم ادعاء تسليمه بعد." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.whatsapp.message.create", error, requestId);
    return { status: "retry", message: "تعذر تسجيل الرد الآن." };
  }
}

export async function addWhatsappNoteAction(
  _previousState: WhatsAppActionState,
  formData: FormData,
): Promise<WhatsAppActionState> {
  const conversationId = value(formData, "conversation_id");
  const noteText = value(formData, "note_text");
  const requestId = randomUUID();
  if (!conversationId || !noteText) return { status: "invalid", message: "اكتب الملاحظة قبل حفظها." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("add_whatsapp_internal_note", {
      p_organization_id: membership.organizationId,
      p_conversation_id: conversationId,
      p_note_text: noteText,
      p_request_id: requestId,
    });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية إضافة ملاحظة.", "تحقق من المحادثة ونص الملاحظة.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.whatsapp.note.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/whatsapp");
    return { status: "success", message: "تم حفظ الملاحظة الداخلية." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.whatsapp.note.create", error, requestId);
    return { status: "retry", message: "تعذر حفظ الملاحظة الآن." };
  }
}
