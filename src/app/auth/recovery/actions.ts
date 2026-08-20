"use server";

import { revalidatePath } from "next/cache";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

export type RecoveryActionState = Readonly<{ status: "idle" | "success" | "invalid" | "retry"; message: string }>;

export async function updatePasswordAction(
  _previousState: RecoveryActionState,
  formData: FormData,
): Promise<RecoveryActionState> {
  const password = String(formData.get("password") ?? "");
  const confirmation = String(formData.get("password_confirmation") ?? "");
  if (password.length < 12 || password !== confirmation) return { status: "invalid", message: "استخدم كلمة مرور من 12 حرفًا على الأقل وتأكد من التطابق." };
  try {
    const client = await createServerSupabaseClient();
    const { data } = await client.auth.getUser();
    if (!data.user) return { status: "retry", message: "انتهت جلسة الاستعادة. اطلب رابطًا جديدًا." };
    const { error } = await client.auth.updateUser({ password });
    if (error) return { status: "retry", message: "تعذر تحديث كلمة المرور الآن." };
    revalidatePath("/sign-in");
    return { status: "success", message: "تم تحديث كلمة المرور. يمكنك الآن الدخول من جديد." };
  } catch {
    return { status: "retry", message: "تعذر تحديث كلمة المرور الآن." };
  }
}
