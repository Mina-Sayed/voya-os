"use client";

import { CircleAlert, LoaderCircle } from "lucide-react";
import { useRef, useState } from "react";
import type { GoogleSignInResult } from "./google-sign-in";
import { isValidInvitationToken } from "./invitation-token";

type GoogleSignInButtonProps = Readonly<{
  configured: boolean;
  onSignIn(invitationToken?: string): Promise<GoogleSignInResult>;
}>;

export function GoogleSignInButton({ configured, onSignIn }: GoogleSignInButtonProps) {
  const [status, setStatus] = useState<GoogleSignInResult["status"] | null>(configured ? null : "unavailable");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const submissionInFlight = useRef(false);

  async function handleClick() {
    if (!configured || submissionInFlight.current) return;
    submissionInFlight.current = true;
    setIsSubmitting(true);
    try {
      const rawToken = new URLSearchParams(window.location.search).get("token");
      const invitationToken = isValidInvitationToken(rawToken) ? rawToken : undefined;
      setStatus((await (invitationToken ? onSignIn(invitationToken) : onSignIn())).status);
    } catch {
      setStatus("retry");
    } finally {
      submissionInFlight.current = false;
      setIsSubmitting(false);
    }
  }

  return (
    <div>
      {status ? (
        <p aria-live="polite" className="mb-3 flex items-start gap-2 text-xs leading-6 text-coral">
          <CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0" />
          {status === "unavailable" ? "تسجيل الدخول عبر Google غير مهيأ في هذه البيئة بعد." : "تعذّر تسجيل الدخول عبر Google الآن. حاول مرة أخرى بعد قليل."}
        </p>
      ) : null}
      <button
        className="flex h-13 w-full items-center justify-center gap-2 rounded-2xl border border-line bg-white px-5 text-sm font-bold text-harbor transition hover:border-tide hover:text-tide disabled:cursor-not-allowed disabled:opacity-60"
        disabled={!configured || isSubmitting}
        onClick={handleClick}
        type="button"
      >
        {isSubmitting ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <span aria-hidden="true" className="grid size-5 place-items-center rounded-full border border-[#4285f4] text-[11px] font-black leading-none text-[#4285f4]">G</span>}
        متابعة باستخدام Google
      </button>
    </div>
  );
}
