"use client";

import { ArrowLeft, CircleAlert, KeyRound, LoaderCircle, UserPlus } from "lucide-react";
import { useRef, useState, type FormEvent } from "react";
import type { PasswordSignUpResult } from "./password-sign-up";
import { isValidInvitationToken, invitationPath } from "./invitation-token";

type PasswordSignUpFormProps = Readonly<{
  configured: boolean;
  onSignUp(email: string, password: string, invitationToken?: string): Promise<PasswordSignUpResult | Readonly<{ status: "unavailable" }>>;
  navigate?: (path: string) => void;
}>;

type FormStatus = PasswordSignUpResult["status"] | "unavailable" | "password_mismatch";

const feedback: Record<Exclude<FormStatus, "signed_in">, string> = {
  created: "تم إنشاء الحساب. افتح رسالة التأكيد، وبعدها أكمل إعداد المؤسسة.",
  invalid_credentials: "استخدم بريدًا صحيحًا وكلمة مرور من 8 أحرف على الأقل.",
  password_mismatch: "كلمتا المرور غير متطابقتين.",
  rate_limited: "تم طلب محاولات تسجيل كثيرة. حاول مرة أخرى لاحقًا.",
  retry: "تعذّر إنشاء الحساب الآن. حاول مرة أخرى بعد قليل.",
  unavailable: "التسجيل غير مهيأ في هذه البيئة بعد.",
};

export function PasswordSignUpForm({ configured, onSignUp, navigate = (path) => window.location.assign(path) }: PasswordSignUpFormProps) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [status, setStatus] = useState<FormStatus | null>(configured ? null : "unavailable");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const submissionInFlight = useRef(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!configured || submissionInFlight.current) return;
    if (password !== confirmation) {
      setStatus("password_mismatch");
      return;
    }

    submissionInFlight.current = true;
    setIsSubmitting(true);
    try {
      const rawToken = new URLSearchParams(window.location.search).get("token");
      const invitationToken = isValidInvitationToken(rawToken) ? rawToken : undefined;
      const result = invitationToken
        ? await onSignUp(email, password, invitationToken)
        : await onSignUp(email, password);
      setStatus(result.status);
      if (result.status === "signed_in") {
        navigate("nextPath" in result && result.nextPath ? result.nextPath : invitationToken ? invitationPath(invitationToken) : "/onboarding");
        setStatus(null);
      }
    } catch {
      setStatus("retry");
    } finally {
      submissionInFlight.current = false;
      setIsSubmitting(false);
    }
  }

  return (
    <form className="mt-8 space-y-4" noValidate onSubmit={handleSubmit}>
      <div>
        <label className="block text-sm font-bold text-harbor" htmlFor="signup-email">البريد الإلكتروني</label>
        <input autoComplete="email" className="ltr mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-left text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas" disabled={!configured || isSubmitting} id="signup-email" inputMode="email" onChange={(event) => setEmail(event.target.value)} placeholder="you@company.com" required type="email" value={email} />
      </div>
      <div>
        <label className="block text-sm font-bold text-harbor" htmlFor="signup-password">كلمة مرور فُويا</label>
        <div className="relative mt-2">
          <KeyRound aria-hidden="true" className="pointer-events-none absolute right-4 top-1/2 size-4 -translate-y-1/2 text-tide" />
          <input autoComplete="new-password" className="h-13 w-full rounded-2xl border border-line bg-white px-11 text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas" disabled={!configured || isSubmitting} id="signup-password" minLength={8} onChange={(event) => setPassword(event.target.value)} required type="password" value={password} />
        </div>
      </div>
      <div>
        <label className="block text-sm font-bold text-harbor" htmlFor="signup-password-confirmation">تأكيد كلمة المرور</label>
        <input autoComplete="new-password" className="ltr mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-left text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas" disabled={!configured || isSubmitting} id="signup-password-confirmation" minLength={8} onChange={(event) => setConfirmation(event.target.value)} required type="password" value={confirmation} />
      </div>
      {status && status !== "signed_in" ? <p aria-live="polite" className={`flex items-start gap-2 text-xs leading-6 ${status === "created" ? "text-tide" : "text-coral"}`}>{status === "created" ? <UserPlus aria-hidden="true" className="mt-1 size-3.5 shrink-0" /> : <CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0" />}{feedback[status]}</p> : null}
      <button className="flex h-13 w-full items-center justify-center gap-2 rounded-2xl border border-tide bg-white px-5 text-sm font-bold text-tide transition hover:bg-sea-glass/35 disabled:cursor-not-allowed disabled:opacity-60" disabled={!configured || isSubmitting} type="submit">
        {isSubmitting ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <ArrowLeft aria-hidden="true" className="size-4" />}
        إنشاء حساب بالبريد
      </button>
    </form>
  );
}
