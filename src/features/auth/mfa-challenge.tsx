"use client";

import { ArrowLeft, CircleAlert, LoaderCircle, RotateCcw } from "lucide-react";
import { useEffect, useState, type FormEvent } from "react";
import { createBrowserSupabaseClient } from "@/lib/supabase/browser-client";

export type MfaChallengeClient = Readonly<{
  auth: Readonly<{
    mfa: Readonly<{
      listFactors(): Promise<Readonly<{ data: unknown; error: unknown }>>;
      challenge(params: Readonly<{ factorId: string }>): Promise<Readonly<{ data: unknown; error: unknown }>>;
      verify(params: Readonly<{ factorId: string; challengeId: string; code: string }>): Promise<Readonly<{ data: unknown; error: unknown }>>;
    }>;
  }>;
}>;

type MfaChallengeProps = Readonly<{
  client?: MfaChallengeClient;
  navigate?: (path: string) => void;
}>;

type TotpFactor = Readonly<{
  id: string;
  friendlyName: string;
}>;

const retryMessage = "تعذّر التحقق من الرمز. حاول مرة أخرى.";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function verifiedTotpFactors(result: unknown): TotpFactor[] | null {
  if (!isRecord(result) || result.error != null || !isRecord(result.data)) return null;
  const factors = result.data.totp;
  if (!Array.isArray(factors)) return null;

  return factors.flatMap((factor, index) => {
    if (
      !isRecord(factor)
      || factor.factor_type !== "totp"
      || factor.status !== "verified"
      || typeof factor.id !== "string"
      || !factor.id
    ) return [];
    const friendlyName = typeof factor.friendly_name === "string" && factor.friendly_name.trim()
      ? factor.friendly_name.trim()
      : `وسيلة تحقق ${index + 1}`;
    return [{ id: factor.id, friendlyName }];
  });
}

function challengeId(result: unknown): string | null {
  if (!isRecord(result) || result.error != null || !isRecord(result.data)) return null;
  return typeof result.data.id === "string" && result.data.id ? result.data.id : null;
}

function verificationSucceeded(result: unknown): boolean {
  return isRecord(result) && result.error == null && isRecord(result.data);
}

export function MfaChallenge({
  client,
  navigate = (path) => window.location.assign(path),
}: MfaChallengeProps) {
  const [resolvedClient, setResolvedClient] = useState<MfaChallengeClient | null>(client ?? null);
  const [factors, setFactors] = useState<readonly TotpFactor[]>([]);
  const [selectedFactorId, setSelectedFactorId] = useState("");
  const [code, setCode] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [loadAttempt, setLoadAttempt] = useState(0);
  const [loadFailed, setLoadFailed] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (resolvedClient) return;
    let active = true;
    const timer = window.setTimeout(() => {
      if (!active) return;
      try {
        setResolvedClient(createBrowserSupabaseClient());
      } catch {
        setLoadFailed(true);
        setIsLoading(false);
      }
    }, 0);
    return () => {
      active = false;
      window.clearTimeout(timer);
    };
  }, [loadAttempt, resolvedClient]);

  useEffect(() => {
    if (!resolvedClient) return;
    const activeClient = resolvedClient;
    let active = true;

    void activeClient.auth.mfa.listFactors()
      .then((result) => {
        if (!active) return;
        const verifiedFactors = verifiedTotpFactors(result);
        if (!verifiedFactors) {
          setLoadFailed(true);
          setFactors([]);
          return;
        }
        setFactors(verifiedFactors);
        setSelectedFactorId((current) => (
          verifiedFactors.some((factor) => factor.id === current)
            ? current
            : verifiedFactors[0]?.id ?? ""
        ));
      })
      .catch(() => {
        if (active) {
          setLoadFailed(true);
          setFactors([]);
        }
      })
      .finally(() => {
        if (active) setIsLoading(false);
      });

    return () => {
      active = false;
    };
  }, [loadAttempt, resolvedClient]);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (isSubmitting || !selectedFactorId || !resolvedClient) return;
    if (!/^\d{6}$/u.test(code)) {
      setError("أدخل رمز تحقق صحيحًا من 6 أرقام.");
      return;
    }

    setIsSubmitting(true);
    setError(null);
    const activeClient = resolvedClient;
    let navigationStarted = false;
    try {
      const challengeResult = await activeClient.auth.mfa.challenge({ factorId: selectedFactorId });
      const id = challengeId(challengeResult);
      if (!id) throw new Error("challenge_failed");

      const verifyResult = await activeClient.auth.mfa.verify({
        factorId: selectedFactorId,
        challengeId: id,
        code,
      });
      if (!verificationSucceeded(verifyResult)) throw new Error("verification_failed");

      navigationStarted = true;
      navigate("/workspace");
    } catch {
      navigationStarted = false;
      setError(retryMessage);
    } finally {
      if (!navigationStarted) setIsSubmitting(false);
    }
  }

  if (isLoading) {
    return <p aria-live="polite" className="mt-7 text-sm text-muted" role="status">جارٍ تحميل وسائل التحقق…</p>;
  }

  if (loadFailed) {
    return (
      <div className="mt-7 space-y-4">
        <p className="flex items-start gap-2 text-sm leading-7 text-coral" role="alert">
          <CircleAlert aria-hidden="true" className="mt-1 size-4 shrink-0" />
          تعذّر تحميل وسائل التحقق. حاول مرة أخرى.
        </p>
        <button
          className="inline-flex items-center gap-2 text-sm font-bold text-tide hover:text-harbor"
          onClick={() => {
            setIsLoading(true);
            setLoadFailed(false);
            setLoadAttempt((attempt) => attempt + 1);
          }}
          type="button"
        >
          <RotateCcw aria-hidden="true" className="size-4" />إعادة المحاولة
        </button>
      </div>
    );
  }

  if (factors.length === 0) {
    return (
      <p className="mt-7 flex items-start gap-2 text-sm leading-7 text-coral" role="alert">
        <CircleAlert aria-hidden="true" className="mt-1 size-4 shrink-0" />
        لا توجد وسيلة TOTP موثّقة لهذا الحساب. تواصل مع مسؤول النظام.
      </p>
    );
  }

  return (
    <form className="mt-7 space-y-5" noValidate onSubmit={handleSubmit}>
      <div>
        <label className="block text-sm font-bold text-harbor" htmlFor="mfa-factor">وسيلة التحقق</label>
        <select
          className="mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas"
          disabled={isSubmitting}
          id="mfa-factor"
          onChange={(event) => setSelectedFactorId(event.target.value)}
          value={selectedFactorId}
        >
          {factors.map((factor) => <option key={factor.id} value={factor.id}>{factor.friendlyName}</option>)}
        </select>
      </div>
      <div>
        <label className="block text-sm font-bold text-harbor" htmlFor="mfa-code">رمز التحقق المكوّن من 6 أرقام</label>
        <input
          autoComplete="one-time-code"
          className="ltr mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-center font-mono text-lg tracking-[0.35em] text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas"
          disabled={isSubmitting}
          id="mfa-code"
          inputMode="numeric"
          maxLength={6}
          onChange={(event) => setCode(event.target.value.replace(/\D/gu, "").slice(0, 6))}
          pattern="[0-9]{6}"
          type="text"
          value={code}
        />
      </div>
      {error ? (
        <p className="flex items-start gap-2 text-sm leading-7 text-coral" role="alert">
          <CircleAlert aria-hidden="true" className="mt-1 size-4 shrink-0" />{error}
        </p>
      ) : null}
      {isSubmitting ? <p aria-live="polite" className="text-xs text-muted">جارٍ التحقق من الرمز…</p> : null}
      <button
        className="flex h-13 w-full items-center justify-center gap-2 rounded-2xl bg-harbor px-5 text-sm font-bold text-white shadow-[0_12px_28px_rgba(17,43,50,0.2)] transition hover:bg-tide disabled:cursor-not-allowed disabled:bg-[#78938c]"
        disabled={isSubmitting}
        type="submit"
      >
        {isSubmitting ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <ArrowLeft aria-hidden="true" className="size-4" />}
        تحقق وافتح مساحة العمل
      </button>
    </form>
  );
}
