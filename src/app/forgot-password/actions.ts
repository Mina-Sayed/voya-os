"use server";

import { resolveApplicationOrigin, internalApplicationUrl } from "@/features/auth/application-origin";
import { isValidEmailAddress, normalizeEmailAddress } from "@/features/auth/email-address";
import { AuthRateLimitUnavailable, consumeAuthRateLimit } from "@/lib/security/auth-rate-limit";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

export type PasswordResetState = Readonly<{
  status: "idle" | "sent" | "invalid" | "rate_limited" | "retry" | "unavailable";
  message: string;
}>;

export async function requestPasswordResetAction(
  _previousState: PasswordResetState,
  formData: FormData,
): Promise<PasswordResetState> {
  const email = normalizeEmailAddress(String(formData.get("email") ?? ""));
  if (!isValidEmailAddress(email)) return { status: "invalid", message: "اكتب بريدًا إلكترونيًا صحيحًا." };
  try {
    if (!await consumeAuthRateLimit({ scope: "password_reset", email })) {
      return { status: "rate_limited", message: "تم تجاوز الحد المؤقت. حاول لاحقًا." };
    }
    const origin = resolveApplicationOrigin({ environment: process.env, requestUrl: "" });
    const client = await createServerSupabaseClient();
    const { error } = await client.auth.resetPasswordForEmail(email, {
      redirectTo: internalApplicationUrl(origin, "/auth/callback").toString(),
    });
    if (error) return { status: "retry", message: "تعذر إرسال رسالة الاستعادة الآن." };
    return { status: "sent", message: "إذا كان البريد مسجلًا، ستصلك رسالة استعادة آمنة." };
  } catch (error) {
    if (error instanceof SupabaseConfigurationError || error instanceof AuthRateLimitUnavailable) return { status: "unavailable", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر إرسال رسالة الاستعادة الآن." };
  }
}
