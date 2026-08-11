import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createServerSupabaseClient: vi.fn(),
  revalidatePath: vi.fn(),
}));

vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: mocks.createServerSupabaseClient,
}));

vi.mock("next/cache", () => ({
  revalidatePath: mocks.revalidatePath,
}));

import { beginMfaEnrollmentAction } from "./actions";

function client({
  factors = [],
  enroll = { data: { id: "new-factor", totp: { qr_code: "<svg />", secret: "secret" } }, error: null },
  unenroll = { data: { id: "pending-factor" }, error: null },
}: {
  factors?: unknown[];
  enroll?: { data: unknown; error: unknown };
  unenroll?: { data: unknown; error: unknown };
}) {
  return {
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: { id: "user-a" } }, error: null }),
      mfa: {
        listFactors: vi.fn().mockResolvedValue({ data: { all: factors }, error: null }),
        unenroll: vi.fn().mockResolvedValue(unenroll),
        enroll: vi.fn().mockResolvedValue(enroll),
      },
    },
  };
}

afterEach(() => {
  vi.clearAllMocks();
});

describe("beginMfaEnrollmentAction", () => {
  it("resets interrupted TOTP enrollment before returning a fresh QR", async () => {
    const pendingFactor = { id: "pending-factor", factor_type: "totp", status: "unverified" };
    const supabase = client({ factors: [pendingFactor] });
    mocks.createServerSupabaseClient.mockResolvedValue(supabase);

    await expect(beginMfaEnrollmentAction({ status: "idle", message: "" }, new FormData())).resolves.toEqual({
      status: "enrollment_started",
      message: "امسح رمز QR بتطبيق المصادقة ثم أدخل الرمز المكوّن من 6 أرقام.",
      factorId: "new-factor",
      qrCode: "<svg />",
      secret: "secret",
    });

    expect(supabase.auth.mfa.unenroll).toHaveBeenCalledWith({ factorId: "pending-factor" });
    expect(supabase.auth.mfa.enroll).toHaveBeenCalledWith({ factorType: "totp", friendlyName: "Voya OS" });
  });

  it("does not reset a verified factor", async () => {
    const verifiedFactor = { id: "verified-factor", factor_type: "totp", status: "verified" };
    const supabase = client({ factors: [verifiedFactor] });
    mocks.createServerSupabaseClient.mockResolvedValue(supabase);

    await expect(beginMfaEnrollmentAction({ status: "idle", message: "" }, new FormData())).resolves.toEqual({
      status: "retry",
      message: "يوجد تطبيق تحقق مفعّل بالفعل. أدخل الرمز للمتابعة.",
    });
    expect(supabase.auth.mfa.unenroll).not.toHaveBeenCalled();
    expect(supabase.auth.mfa.enroll).not.toHaveBeenCalled();
  });

  it("fails safely when the pending factor cannot be removed", async () => {
    const pendingFactor = { id: "pending-factor", factor_type: "totp", status: "unverified" };
    const supabase = client({ factors: [pendingFactor], unenroll: { data: null, error: new Error("provider secret") } });
    mocks.createServerSupabaseClient.mockResolvedValue(supabase);

    await expect(beginMfaEnrollmentAction({ status: "idle", message: "" }, new FormData())).resolves.toEqual({
      status: "retry",
      message: "تعذّر إعادة بدء إعداد تطبيق التحقق.",
    });
    expect(supabase.auth.mfa.enroll).not.toHaveBeenCalled();
  });
});
