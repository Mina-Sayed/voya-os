"use client";

import { useActionState, useEffect } from "react";
import Image from "next/image";
import { LoaderCircle, LockKeyhole, ShieldCheck } from "lucide-react";
import { beginMfaEnrollmentAction, verifyMfaAction, type MfaActionState } from "@/app/security/mfa/actions";

type MfaPageProps = Readonly<{
  reason: "enrollment" | "challenge";
  verifiedFactorId: string | null;
}>;

const idleState: MfaActionState = { status: "idle", message: "" };

function Feedback({ state }: Readonly<{ state: MfaActionState }>) {
  if (state.status === "idle") return null;
  return <p aria-live="polite" className={`mt-4 text-xs leading-6 ${state.status === "success" || state.status === "enrollment_started" ? "text-tide" : "text-coral"}`}>{state.message}</p>;
}

function VerifyForm({ factorId, initialState = idleState }: Readonly<{ factorId: string; initialState?: MfaActionState }>) {
  const [state, action, pending] = useActionState(verifyMfaAction, initialState);
  useEffect(() => {
    if (state.status === "success") window.location.assign("/workspace");
  }, [state.status]);
  return <form action={action} className="mt-6 space-y-4"><input name="factor_id" type="hidden" value={factorId} /><label className="block text-sm font-bold text-harbor" htmlFor="mfa-code">رمز تطبيق المصادقة<input autoComplete="one-time-code" className="ltr mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-center font-mono text-lg tracking-[0.35em] outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35" id="mfa-code" inputMode="numeric" maxLength={6} minLength={6} name="code" pattern="[0-9]{6}" required /></label><button className="flex h-13 w-full items-center justify-center gap-2 rounded-2xl bg-harbor px-5 text-sm font-bold text-white transition hover:bg-tide disabled:cursor-not-allowed disabled:bg-[#78938c]" disabled={pending} type="submit">{pending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <ShieldCheck aria-hidden="true" className="size-4" />}تحقق وادخل مساحة العمل</button><Feedback state={state} /></form>;
}

function EnrollmentPanel() {
  const [state, action, pending] = useActionState(beginMfaEnrollmentAction, idleState);
  const factorId = state.factorId ?? null;
  return <>
    {!state.qrCode ? <form action={action}><button className="mt-6 flex h-13 w-full items-center justify-center gap-2 rounded-2xl bg-harbor px-5 text-sm font-bold text-white transition hover:bg-tide disabled:cursor-not-allowed disabled:bg-[#78938c]" disabled={pending} type="submit">{pending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <LockKeyhole aria-hidden="true" className="size-4" />}ابدأ إعداد تطبيق المصادقة</button><Feedback state={state} /></form> : null}
    {state.qrCode && factorId ? <div className="mt-6 space-y-5"><div className="grid place-items-center rounded-2xl border border-line bg-white p-5"><Image alt="رمز QR لإعداد تطبيق المصادقة" className="size-52" height={208} src={`data:image/svg+xml;utf8,${encodeURIComponent(state.qrCode)}`} unoptimized width={208} /></div><p className="text-xs leading-6 text-muted">إذا لم يعمل المسح، أدخل المفتاح يدويًا:</p><code className="block select-all rounded-xl bg-canvas p-3 text-center text-xs tracking-[0.2em] text-ink">{state.secret}</code><VerifyForm factorId={factorId} /></div> : null}
  </>;
}

export function MfaPage({ reason, verifiedFactorId }: MfaPageProps) {
  const isEnrollment = reason === "enrollment" || !verifiedFactorId;
  return <main className="grid min-h-screen place-items-center bg-canvas px-4 py-8 text-ink"><section className="w-full max-w-xl rounded-[2rem] border border-line bg-surface p-7 shadow-[0_24px_70px_rgba(16,33,38,0.08)] sm:p-10"><div className="mx-auto grid size-14 place-items-center rounded-2xl bg-sea-glass/45 text-tide"><ShieldCheck aria-hidden="true" className="size-7" /></div><p className="mt-6 text-center text-xs font-bold text-tide">حماية مساحة العمل</p><h1 className="mt-3 text-center text-3xl font-bold tracking-[-0.09em] text-harbor">تحقق بخطوتين مطلوب</h1><p className="mx-auto mt-4 max-w-md text-center text-sm leading-7 text-muted">كل مستخدمي مساحة العمل يحتاجون جلسة AAL2. لا نرسل رموز التحقق إلى البريد ولا نحفظ المفتاح في سجلات التطبيق.</p>{isEnrollment ? <EnrollmentPanel /> : <VerifyForm factorId={verifiedFactorId} />}<p className="mt-6 border-t border-line pt-5 text-center text-xs leading-6 text-muted">استخدم تطبيقًا مثل Google Authenticator أو 1Password. إذا فقدت جهازك، اطلب إعادة ضبط العامل من مسؤول المؤسسة.</p></section></main>;
}
