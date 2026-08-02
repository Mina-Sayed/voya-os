"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { PropertyCreateState } from "@/features/properties/property-create-form";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

function formValue(formData: FormData, key: string): string | null {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : null;
}

export async function createPropertyAction(
  _previousState: PropertyCreateState,
  formData: FormData,
): Promise<PropertyCreateState> {
  const code = formValue(formData, "code");
  const name = formValue(formData, "name");
  const timezone = formValue(formData, "timezone");
  const idempotencyKey = formValue(formData, "idempotency_key");
  if (!code || !name || !timezone || !idempotencyKey) return { status: "invalid", message: "أكمل رمز العقار واسمه ومنطقته الزمنية للمتابعة." };
  const requestId = randomUUID();

  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة لإضافة عقار." };
    const client = await createServerSupabaseClient();

    const { error } = await client.rpc("create_property", { p_organization_id: membership.organizationId, p_code: code, p_name: name, p_timezone: timezone, p_idempotency_key: idempotencyKey, p_request_id: requestId });
    if (error) {
      if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية إضافة عقار." };
      if (error.code === "22023") return { status: "invalid", message: "تحقق من بيانات العقار ثم أعد المحاولة." };
      reportWorkspaceActionFailure("workspace.property.create", error, requestId);
      return { status: "retry", message: "تعذر حفظ العقار الآن. حاول مرة أخرى." };
    }
    revalidatePath("/workspace/properties");
    return { status: "success", message: "تمت إضافة العقار." };
  } catch (error) { reportWorkspaceActionFailure("workspace.property.create", error, requestId);
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر حفظ العقار الآن. حاول مرة أخرى." };
  }
}
