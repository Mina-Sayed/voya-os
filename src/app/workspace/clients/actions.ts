"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import type { ClientCreateState } from "@/features/clients/client-create-form";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

function formValue(formData: FormData, key: string) { const value = formData.get(key); return typeof value === "string" ? value.trim() : null; }

export async function createClientAction(_previousState: ClientCreateState, formData: FormData): Promise<ClientCreateState> {
  const displayName = formValue(formData, "display_name");
  const idempotencyKey = formValue(formData, "idempotency_key");
  if (!displayName || !idempotencyKey) return { status: "invalid", message: "اكتب اسم العميل للمتابعة." };
  try {
    const client = await createServerSupabaseClient();
    const { data: userData } = await client.auth.getUser();
    if (!userData.user) return { status: "denied", message: "انتهت الجلسة. سجّل الدخول مرة أخرى." };
    const { data: memberships } = await client.from("organization_memberships").select("id, organization_id, role, status").eq("user_id", userData.user.id).limit(2);
    const membership = resolveActiveMembership((memberships ?? []).map((item) => ({ id: item.id, organizationId: item.organization_id, role: item.role, status: item.status })));
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لإضافة عميل." };
    const { error } = await client.rpc("create_client", { p_organization_id: membership.organizationId, p_display_name: displayName, p_idempotency_key: idempotencyKey, p_request_id: randomUUID() });
    if (error) {
      if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إضافة عميل." };
      if (error.code === "22023") return { status: "invalid", message: "تحقق من اسم العميل ثم أعد المحاولة." };
      return { status: "retry", message: "تعذر حفظ العميل الآن. حاول مرة أخرى." };
    }
    revalidatePath("/workspace/clients");
    return { status: "success", message: "تمت إضافة العميل." };
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر حفظ العميل الآن. حاول مرة أخرى." };
  }
}
