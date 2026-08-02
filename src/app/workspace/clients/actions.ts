"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { ClientCreateState } from "@/features/clients/client-create-form";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

function formValue(formData: FormData, key: string) { const value = formData.get(key); return typeof value === "string" ? value.trim() : null; }

export async function createClientAction(_previousState: ClientCreateState, formData: FormData): Promise<ClientCreateState> {
  const displayName = formValue(formData, "display_name");
  const idempotencyKey = formValue(formData, "idempotency_key");
  if (!displayName || !idempotencyKey) return { status: "invalid", message: "اكتب اسم العميل للمتابعة." };
  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لإضافة عميل." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_client", { p_organization_id: membership.organizationId, p_display_name: displayName, p_idempotency_key: idempotencyKey, p_request_id: requestId });
    if (error) {
      if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إضافة عميل." };
      if (error.code === "22023") return { status: "invalid", message: "تحقق من اسم العميل ثم أعد المحاولة." };
      reportWorkspaceActionFailure("workspace.client.create", error, requestId);
      return { status: "retry", message: "تعذر حفظ العميل الآن. حاول مرة أخرى." };
    }
    revalidatePath("/workspace/clients");
    return { status: "success", message: "تمت إضافة العميل." };
  } catch (error) { reportWorkspaceActionFailure("workspace.client.create", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر حفظ العميل الآن. حاول مرة أخرى." };
  }
}
