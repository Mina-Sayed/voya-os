"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useActionState, useEffect } from "react";
import { updatePasswordAction, type RecoveryActionState } from "./actions";

const initialState: RecoveryActionState = { status: "idle", message: "" };

export default function RecoveryPage() {
  const [state, action, pending] = useActionState(updatePasswordAction, initialState);
  const router = useRouter();
  useEffect(() => {
    if (state.status !== "success") return;
    const timeoutId = window.setTimeout(() => router.replace("/workspace"), 900);
    return () => window.clearTimeout(timeoutId);
  }, [router, state.status]);
  return <main className="grid min-h-screen place-items-center bg-canvas px-4 py-8 text-ink"><section className="w-full max-w-md rounded-[2rem] border border-line bg-surface p-7 shadow-[0_24px_70px_rgba(16,33,38,0.08)] sm:p-10"><p className="text-xs font-bold text-tide">رابط استعادة موثّق</p><h1 className="mt-3 text-3xl font-bold tracking-[-0.09em] text-harbor">ضع كلمة مرور جديدة</h1><p className="mt-4 text-sm leading-7 text-muted">بعد الحفظ ستبقى حماية MFA ومسار المؤسسة مطلوبة قبل فتح التشغيل.</p><form action={action} className="mt-7 space-y-4"><label className="block text-sm font-bold text-harbor" htmlFor="new-password">كلمة المرور الجديدة<input autoComplete="new-password" className="mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-sm font-normal outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35" id="new-password" minLength={12} name="password" required type="password" /></label><label className="block text-sm font-bold text-harbor" htmlFor="new-password-confirmation">تأكيد كلمة المرور<input autoComplete="new-password" className="mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-sm font-normal outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35" id="new-password-confirmation" minLength={12} name="password_confirmation" required type="password" /></label><button className="h-13 w-full rounded-2xl bg-harbor text-sm font-bold text-white transition hover:bg-tide disabled:opacity-60" disabled={pending} type="submit">{pending ? "جارٍ الحفظ…" : "حفظ كلمة المرور"}</button>{state.status !== "idle" ? <p aria-live="polite" className={`text-xs leading-6 ${state.status === "success" ? "text-tide" : "text-coral"}`}>{state.message}</p> : null}</form><Link className="mt-6 block text-center text-xs font-bold text-tide hover:text-harbor" href="/sign-in">العودة إلى تسجيل الدخول</Link></section></main>;
}
