"use client";

import { ArrowLeft, CircleAlert, KeyRound, LoaderCircle } from "lucide-react";
import { useRef, useState, type FormEvent } from "react";
import type { PasswordSignInResult } from "./password-sign-in";

type PasswordSignInFormProps = Readonly<{
  configured: boolean;
  onSignIn(email: string, password: string): Promise<PasswordSignInResult | Readonly<{ status: "unavailable" }>>;
  navigate?: (path: string) => void;
}>;

type FormStatus = PasswordSignInResult["status"] | "unavailable";

const feedback: Record<Exclude<FormStatus, "signed_in">, string> = {
  invalid_credentials: "البريد الإلكتروني أو كلمة المرور غير صحيحة.",
  rate_limited: "تم طلب محاولات كثيرة. انتظر قليلًا ثم حاول مرة أخرى.",
  retry: "تعذّر تسجيل الدخول الآن. حاول مرة أخرى بعد قليل.",
  unavailable: "الدخول غير مهيأ في هذه البيئة بعد.",
};

export function PasswordSignInForm({ configured, onSignIn, navigate = (path) => window.location.assign(path) }: PasswordSignInFormProps) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [status, setStatus] = useState<FormStatus | null>(configured ? null : "unavailable");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const submissionInFlight = useRef(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!configured || submissionInFlight.current) return;

    submissionInFlight.current = true;
    setIsSubmitting(true);
    try {
      const result = await onSignIn(email, password);
      setStatus(result.status);
      if (result.status === "signed_in") {
        navigate("/workspace");
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
        <label className="block text-sm font-bold text-harbor" htmlFor="password-email">البريد الإلكتروني</label>
        <input
          autoComplete="email"
          className="ltr mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-left text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas"
          disabled={!configured || isSubmitting}
          id="password-email"
          inputMode="email"
          onChange={(event) => setEmail(event.target.value)}
          placeholder="you@company.com"
          type="email"
          value={email}
        />
      </div>
      <div>
        <label className="block text-sm font-bold text-harbor" htmlFor="password">كلمة المرور</label>
        <div className="relative mt-2">
          <KeyRound aria-hidden="true" className="pointer-events-none absolute right-4 top-1/2 size-4 -translate-y-1/2 text-tide" />
          <input
            autoComplete="current-password"
            className="h-13 w-full rounded-2xl border border-line bg-white px-11 text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas"
            disabled={!configured || isSubmitting}
            id="password"
            minLength={8}
            onChange={(event) => setPassword(event.target.value)}
            type="password"
            value={password}
          />
        </div>
      </div>
      {status && status !== "signed_in" ? (
        <p aria-live="polite" className="flex items-start gap-2 text-xs leading-6 text-coral">
          <CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0" />
          {feedback[status]}
        </p>
      ) : null}
      {isSubmitting ? <p aria-live="polite" className="text-xs text-muted">جارٍ فتح مساحة العمل…</p> : null}
      <button
        className="flex h-13 w-full items-center justify-center gap-2 rounded-2xl bg-harbor px-5 text-sm font-bold text-white shadow-[0_12px_28px_rgba(17,43,50,0.2)] transition hover:bg-tide disabled:cursor-not-allowed disabled:bg-[#78938c]"
        disabled={!configured || isSubmitting}
        type="submit"
      >
        {isSubmitting ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <ArrowLeft aria-hidden="true" className="size-4" />}
        دخول بالبريد وكلمة المرور
      </button>
    </form>
  );
}
