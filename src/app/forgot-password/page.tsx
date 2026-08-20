"use client";

import Link from "next/link";
import { useActionState } from "react";
import { requestPasswordResetAction, type PasswordResetState } from "./actions";

const initialState: PasswordResetState = { status: "idle", message: "" };

export default function ForgotPasswordPage() {
  const [state, action, pending] = useActionState(requestPasswordResetAction, initialState);
  return <main className="grid min-h-screen place-items-center bg-canvas px-4 py-8 text-ink"><section className="w-full max-w-md rounded-[2rem] border border-line bg-surface p-7 shadow-[0_24px_70px_rgba(16,33,38,0.08)] sm:p-10"><p className="text-xs font-bold text-tide">استعادة الوصول</p><h1 className="mt-3 text-3xl font-bold tracking-[-0.09em] text-harbor">نسيت كلمة المرور؟</h1><p className="mt-4 text-sm leading-7 text-muted">سنرسل رابطًا مؤقتًا إلى البريد. لا نكشف ما إذا كان البريد مسجلًا في النظام.</p><form action={action} className="mt-7 space-y-4"><label className="block text-sm font-bold text-harbor" htmlFor="reset-email">البريد الإلكتروني<input autoComplete="email" className="mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-sm font-normal outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35" id="reset-email" name="email" required type="email" /></label><button className="h-13 w-full rounded-2xl bg-harbor text-sm font-bold text-white transition hover:bg-tide disabled:opacity-60" disabled={pending} type="submit">{pending ? "جارٍ الإرسال…" : "إرسال رابط الاستعادة"}</button>{state.status !== "idle" ? <p aria-live="polite" className={`text-xs leading-6 ${state.status === "sent" ? "text-tide" : "text-coral"}`}>{state.message}</p> : null}</form><Link className="mt-6 block text-center text-xs font-bold text-tide hover:text-harbor" href="/sign-in">العودة إلى تسجيل الدخول</Link></section></main>;
}
