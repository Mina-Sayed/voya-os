"use server";

import { randomUUID } from "node:crypto";
import { resolveApplicationOrigin, internalApplicationUrl } from "@/features/auth/application-origin";
import { isValidEmailAddress, normalizeEmailAddress } from "@/features/auth/email-address";
import { reportOperationalError } from "@/lib/observability/operational-error";
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
    if (error) {
      // Supabase answers 5xx when its SMTP relay rejects delivery (for example
      // Gmail 535 after an App Password rotation). Log it with a request id so
      // operators can find it; the user keeps the generic retry message.
      const status = typeof (error as { status?: unknown }).status === "number" ? (error as { status: number }).status : null;
      reportOperationalError({
        operation: "auth.password_reset",
        requestId: randomUUID(),
        code: status !== null && status >= 500 ? "password_reset_delivery_failed" : "password_reset_rejected",
        outcome: "unavailable",
        cause: error,
      });
      return { status: "retry", message: "تعذر إرسال رسالة الاستعادة الآن." };
    }
    return { status: "sent", message: "إذا كان البريد مسجلًا، ستصلك رسالة استعادة آمنة." };
  } catch (error) {
    if (error instanceof SupabaseConfigurationError || error instanceof AuthRateLimitUnavailable) return { status: "unavailable", message: "الخدمة غير مهيأة في هذه البيئة." };
    return { status: "retry", message: "تعذر إرسال رسالة الاستعادة الآن." };
  }
}
