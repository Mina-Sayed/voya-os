"use server";

import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { z } from "zod";
import { loadActiveWorkspaceMemberships } from "@/features/auth/workspace-context";
import { reportOperationalError } from "@/lib/observability/operational-error";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

const onboardingSchema = z.object({
  name: z.string().trim().min(2).max(160),
  timezone: z.string().trim().min(1).max(80),
  defaultCurrency: z.string().trim().regex(/^[A-Z]{3}$/),
});

export type OnboardingActionState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
}>;

export async function createOrganizationAction(
  _previousState: OnboardingActionState,
  formData: FormData,
): Promise<OnboardingActionState> {
  const requestId = randomUUID();
  const parsed = onboardingSchema.safeParse({
    name: formData.get("name"),
    timezone: formData.get("timezone"),
    defaultCurrency: formData.get("default_currency"),
  });
  if (!parsed.success) return { status: "invalid", message: "أدخل اسم المؤسسة والمنطقة الزمنية والعملة بشكل صحيح." };

  let created = false;
  try {
    const memberships = await loadActiveWorkspaceMemberships();
    if (memberships.state === "signed_out") return { status: "denied", message: "انتهت جلسة الدخول. أعد تسجيل الدخول." };
    if (memberships.memberships.length > 0) return { status: "denied", message: "لديك مؤسسة مرتبطة بالحساب بالفعل." };

    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_organization", {
      p_name: parsed.data.name,
      p_timezone: parsed.data.timezone,
      p_default_currency: parsed.data.defaultCurrency,
      p_request_id: requestId,
    });
    if (error) {
      if (error.code === "42501" || error.code === "23505") return { status: "denied", message: "لا يمكن إنشاء المؤسسة لهذا الحساب." };
      if (error.code === "22023") return { status: "invalid", message: "تحقق من بيانات المؤسسة." };
      reportOperationalError({ operation: "onboarding.create_organization", requestId, code: "organization_create_failed", outcome: "unavailable", cause: error });
      return { status: "retry", message: "تعذر إنشاء المؤسسة الآن. حاول مرة أخرى." };
    }
    created = true;
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) return { status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." };
    reportOperationalError({ operation: "onboarding.create_organization", requestId, code: "organization_create_dependency_failed", outcome: "unavailable", cause: error });
    return { status: "retry", message: "تعذر إنشاء المؤسسة الآن. حاول مرة أخرى." };
  }
  if (created) redirect("/workspace");
  return { status: "success", message: "تم إنشاء المؤسسة." };
}
