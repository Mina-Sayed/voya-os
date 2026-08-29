"use client";

import { ArrowLeft, CircleAlert, KeyRound, LoaderCircle } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useRef, useState, useSyncExternalStore, type FormEvent } from "react";
import type { PasswordSignInResult } from "./password-sign-in";
import { isValidInvitationToken, invitationPath } from "./invitation-token";

type PasswordSignInFormProps = Readonly<{
  configured: boolean;
  onSignIn(email: string, password: string, invitationToken?: string): Promise<PasswordSignInResult | Readonly<{ status: "unavailable" }>>;
  navigate?: (path: string) => void;
}>;

type FormStatus = PasswordSignInResult["status"] | "unavailable";

const feedback: Record<Exclude<FormStatus, "signed_in">, string> = {
  invalid_credentials: "البريد الإلكتروني أو كلمة المرور غير صحيحة.",
  rate_limited: "تم طلب محاولات كثيرة. انتظر قليلًا ثم حاول مرة أخرى.",
  retry: "تعذّر تسجيل الدخول الآن. حاول مرة أخرى بعد قليل.",
  unavailable: "الدخول غير مهيأ في هذه البيئة بعد.",
};

const REMEMBERED_EMAIL_KEY = "voya.auth.remembered-email.v1";
const REMEMBER_EMAIL_PREFERENCE_KEY = "voya.auth.remember-email.v1";

function readLocalStorage(key: string): string | null {
  if (typeof window === "undefined") return null;
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function subscribeToAuthStorage(onStoreChange: () => void): () => void {
  if (typeof window === "undefined") return () => undefined;
  const handleStorage = (event: StorageEvent) => {
    if (event.storageArea === window.localStorage && (event.key === null || event.key === REMEMBERED_EMAIL_KEY || event.key === REMEMBER_EMAIL_PREFERENCE_KEY)) {
      onStoreChange();
    }
  };
  window.addEventListener("storage", handleStorage);
  return () => window.removeEventListener("storage", handleStorage);
}

function getRememberedEmailSnapshot(): string {
  return readLocalStorage(REMEMBERED_EMAIL_KEY) ?? "";
}

function getRememberEmailPreferenceSnapshot(): boolean {
  return readLocalStorage(REMEMBER_EMAIL_PREFERENCE_KEY) !== "0";
}

function writeRememberedEmail(email: string, rememberEmail: boolean): void {
  try {
    window.localStorage.setItem(REMEMBER_EMAIL_PREFERENCE_KEY, rememberEmail ? "1" : "0");
    if (rememberEmail) {
      window.localStorage.setItem(REMEMBERED_EMAIL_KEY, email.trim());
    } else {
      window.localStorage.removeItem(REMEMBERED_EMAIL_KEY);
    }
  } catch {
    // Private browsing and restrictive browser policies can disable storage.
  }
}

export function PasswordSignInForm({ configured, onSignIn, navigate }: PasswordSignInFormProps) {
  const router = useRouter();
  const navigateTo = navigate ?? ((path: string) => router.replace(path));
  const rememberedEmail = useSyncExternalStore(subscribeToAuthStorage, getRememberedEmailSnapshot, () => "");
  const storedRememberEmail = useSyncExternalStore(subscribeToAuthStorage, getRememberEmailPreferenceSnapshot, () => true);
  const [emailOverride, setEmailOverride] = useState<string | null>(null);
  const [rememberEmailOverride, setRememberEmailOverride] = useState<boolean | null>(null);
  const [password, setPassword] = useState("");
  const [status, setStatus] = useState<FormStatus | null>(configured ? null : "unavailable");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const submissionInFlight = useRef(false);
  const email = emailOverride ?? rememberedEmail;
  const rememberEmail = rememberEmailOverride ?? storedRememberEmail;

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!configured || submissionInFlight.current) return;

    submissionInFlight.current = true;
    setIsSubmitting(true);
    try {
      const rawToken = new URLSearchParams(window.location.search).get("token");
      const invitationToken = isValidInvitationToken(rawToken) ? rawToken : undefined;
      const result = invitationToken
        ? await onSignIn(email, password, invitationToken)
        : await onSignIn(email, password);
      setStatus(result.status);
      if (result.status === "signed_in") {
        writeRememberedEmail(email, rememberEmail);
        navigateTo("result" in result && result.nextPath ? result.nextPath : invitationToken ? invitationPath(invitationToken) : "/workspace");
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
    <form autoComplete="on" className="mt-8 space-y-4" noValidate onSubmit={handleSubmit}>
      <div>
        <label className="block text-sm font-bold text-harbor" htmlFor="password-email">البريد الإلكتروني</label>
        <input
          autoComplete="email"
          className="ltr mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-left text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas"
          disabled={!configured || isSubmitting}
          id="password-email"
          inputMode="email"
          name="email"
          onChange={(event) => setEmailOverride(event.target.value)}
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
            name="password"
            onChange={(event) => setPassword(event.target.value)}
            type="password"
            value={password}
          />
        </div>
      </div>
      <label className="flex items-center gap-2 text-xs text-muted">
        <input
          checked={rememberEmail}
          className="size-4 rounded border-line accent-tide"
          disabled={!configured || isSubmitting}
          onChange={(event) => {
            const nextValue = event.target.checked;
            setRememberEmailOverride(nextValue);
            writeRememberedEmail(email, nextValue);
          }}
          type="checkbox"
        />
        تذكر البريد الإلكتروني على هذا الجهاز
      </label>
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
      <Link className="block text-center text-xs font-bold text-tide hover:text-harbor" href="/forgot-password">نسيت كلمة المرور؟</Link>
    </form>
  );
}
