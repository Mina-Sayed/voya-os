"use server";

import { revalidatePath } from "next/cache";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

// Owners/managers are asked to keep a second device as their recovery path
// (Supabase TOTP has no backup codes). Two is enough and keeps support simple.
const MAX_VERIFIED_TOTP_FACTORS = 2;

export type MfaActionState = Readonly<{
  status: "idle" | "enrollment_started" | "success" | "invalid" | "retry";
  message: string;
  factorId?: string;
  qrCode?: string;
  secret?: string;
}>;

export async function beginMfaEnrollmentAction(
  previousState: MfaActionState,
  formData: FormData,
): Promise<MfaActionState> {
  void previousState;
  void formData;
  try {
    const client = await createServerSupabaseClient();
    const userResult = await client.auth.getUser();
    if (userResult.error || !userResult.data.user) return { status: "retry", message: "انتهت جلسة الدخول. أعد فتح الصفحة وحاول مرة أخرى." };

    const factorsResult = await client.auth.mfa.listFactors();
    if (factorsResult.error) return { status: "retry", message: "تعذّر قراءة إعدادات التحقق الآن." };
    const verifiedCount = (factorsResult.data?.all ?? []).filter((factor) => factor.factor_type === "totp" && factor.status === "verified").length;
    if (verifiedCount >= MAX_VERIFIED_TOTP_FACTORS) {
      return { status: "retry", message: "لديك تطبيقا تحقق مفعّلان بالفعل، وهو الحد الأقصى." };
    }
    if (verifiedCount > 0) {
      // A backup factor may only be added from a session that already passed
      // MFA, so a stolen password alone can never register a new device.
      const sessionResult = await client.auth.getSession();
      const accessToken = sessionResult.data.session?.access_token;
      const aalResult = accessToken ? await client.auth.mfa.getAuthenticatorAssuranceLevel(accessToken) : null;
      if (!aalResult || aalResult.error || aalResult.data?.currentLevel !== "aal2") {
        return { status: "retry", message: "يوجد تطبيق تحقق مفعّل بالفعل. أدخل الرمز للمتابعة." };
      }
    }

    // A previous interrupted enrollment leaves an unverified factor behind.
    // Supabase rejects a second factor with the same friendly name, so a new
    // enrollment explicitly resets only those incomplete TOTP attempts.
    const pendingFactors = (factorsResult.data?.all ?? []).filter(
      (factor) => factor.factor_type === "totp" && factor.status === "unverified",
    );
    for (const factor of pendingFactors) {
      const unenrollResult = await client.auth.mfa.unenroll({ factorId: factor.id });
      if (unenrollResult.error) return { status: "retry", message: "تعذّر إعادة بدء إعداد تطبيق التحقق." };
    }

    const result = await client.auth.mfa.enroll({ factorType: "totp", friendlyName: verifiedCount === 0 ? "Voya OS" : "Voya OS (backup)" });
    if (result.error || !result.data?.totp) return { status: "retry", message: "تعذّر بدء إعداد تطبيق التحقق." };
    return {
      status: "enrollment_started",
      message: "امسح رمز QR بتطبيق المصادقة ثم أدخل الرمز المكوّن من 6 أرقام.",
      factorId: result.data.id,
      qrCode: result.data.totp.qr_code,
      secret: result.data.totp.secret,
    };
  } catch {
    return { status: "retry", message: "تعذّر بدء إعداد التحقق الآن." };
  }
}

export async function verifyMfaAction(
  _previousState: MfaActionState,
  formData: FormData,
): Promise<MfaActionState> {
  const factorId = String(formData.get("factor_id") ?? "").trim();
  const code = String(formData.get("code") ?? "").trim();
  if (factorId.length < 8 || factorId.length > 160 || !/^\d{6}$/.test(code)) {
    return { status: "invalid", message: "أدخل رمز التحقق المكوّن من 6 أرقام." };
  }

  try {
    const client = await createServerSupabaseClient();
    const result = await client.auth.mfa.challengeAndVerify({ factorId, code });
    if (result.error) return { status: "retry", message: "رمز التحقق غير صحيح أو انتهت صلاحيته." };
    revalidatePath("/workspace");
    return { status: "success", message: "تم تفعيل التحقق. جارٍ فتح مساحة العمل…" };
  } catch {
    return { status: "retry", message: "تعذّر إكمال التحقق الآن." };
  }
}
