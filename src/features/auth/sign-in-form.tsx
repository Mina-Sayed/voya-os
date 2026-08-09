"use client";

import { ArrowLeft, AtSign, CircleAlert, LoaderCircle, Send } from "lucide-react";
import { useEffect, useState, type FormEvent } from "react";

type SignInStatus = "sent" | "invalid_email" | "rate_limited" | "retry" | "unavailable";

type SignInFormProps = Readonly<{
  configured: boolean;
  onRequestSignIn(email: string): Promise<Readonly<{ status: SignInStatus }>>;
}>;

const feedback: Record<SignInStatus, string> = {
  sent: "أرسلنا رابطًا آمنًا إلى بريدك الإلكتروني.",
  invalid_email: "اكتب بريدًا إلكترونيًا صالحًا للمتابعة.",
  rate_limited: "تم طلب روابط كثيرة. انتظر دقيقة ثم استخدم أحدث رابط فقط.",
  retry: "تعذّر إرسال الرابط الآن. حاول مرة أخرى بعد قليل.",
  unavailable: "الدخول غير مهيأ في هذه البيئة بعد.",
};

export function SignInForm({ configured, onRequestSignIn }: SignInFormProps) {
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<SignInStatus | null>(configured ? null : "unavailable");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [cooldownSeconds, setCooldownSeconds] = useState(0);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!configured || isSubmitting) return;

    setIsSubmitting(true);
    const result = await onRequestSignIn(email);
    setStatus(result.status);
    if (result.status === "rate_limited") setCooldownSeconds(60);
    setIsSubmitting(false);
  }

  useEffect(() => {
    if (cooldownSeconds === 0) return;
    const timer = window.setInterval(() => {
      setCooldownSeconds((current) => Math.max(0, current - 1));
    }, 1_000);
    return () => window.clearInterval(timer);
  }, [cooldownSeconds]);

  return (
    <form className="mt-8" noValidate onSubmit={handleSubmit}>
      <label className="block text-sm font-bold text-harbor" htmlFor="email">البريد الإلكتروني</label>
      <div className="relative mt-2">
        <AtSign aria-hidden="true" className="pointer-events-none absolute right-4 top-1/2 size-4 -translate-y-1/2 text-tide" />
        <input
          autoComplete="email"
          className="ltr h-13 w-full rounded-2xl border border-line bg-white px-11 text-left text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas"
          disabled={!configured || isSubmitting}
          id="email"
          inputMode="email"
          name="email"
          onChange={(event) => setEmail(event.target.value)}
          placeholder="you@company.com"
          type="email"
          value={email}
        />
      </div>
      {status ? (
        <p aria-live="polite" className={`mt-3 flex items-start gap-2 text-xs leading-6 ${status === "sent" ? "text-tide" : "text-coral"}`}>
          {status === "sent" ? <Send aria-hidden="true" className="mt-1 size-3.5 shrink-0" /> : <CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0" />}
          {feedback[status]}
        </p>
      ) : null}
      <button
        className="mt-6 flex h-13 w-full items-center justify-center gap-2 rounded-2xl bg-harbor px-5 text-sm font-bold text-white shadow-[0_12px_28px_rgba(17,43,50,0.2)] transition hover:bg-tide disabled:cursor-not-allowed disabled:bg-[#78938c]"
        disabled={!configured || isSubmitting || cooldownSeconds > 0}
        type="submit"
      >
        {isSubmitting ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <ArrowLeft aria-hidden="true" className="size-4" />}
        {cooldownSeconds > 0 ? `حاول بعد ${cooldownSeconds} ثانية` : "أرسل رابط الدخول"}
      </button>
    </form>
  );
}
