"use client";

import { ArrowLeft, CircleAlert, LoaderCircle } from "lucide-react";
import { useActionState } from "react";
import type { OnboardingActionState } from "@/app/onboarding/actions";

type OnboardingFormProps = Readonly<{
  action: (state: OnboardingActionState, formData: FormData) => Promise<OnboardingActionState>;
}>;

const initialState: OnboardingActionState = { status: "idle", message: "" };

export function OnboardingForm({ action }: OnboardingFormProps) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return (
    <form action={formAction} className="mt-8 space-y-5">
      <label className="block text-sm font-bold text-harbor" htmlFor="organization-name">اسم المؤسسة<input className="mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-sm font-normal text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35" id="organization-name" maxLength={160} name="name" placeholder="شركة فُويا للتشغيل" required /></label>
      <label className="block text-sm font-bold text-harbor" htmlFor="organization-timezone">المنطقة الزمنية<input className="ltr mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-left text-sm font-normal text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35" defaultValue="Africa/Cairo" id="organization-timezone" maxLength={80} name="timezone" required /></label>
      <label className="block text-sm font-bold text-harbor" htmlFor="organization-currency">العملة الافتراضية<select className="mt-2 h-13 w-full rounded-2xl border border-line bg-white px-4 text-sm font-normal text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35" defaultValue="EGP" id="organization-currency" name="default_currency"><option value="EGP">EGP — جنيه مصري</option></select></label>
      {state.status !== "idle" && state.status !== "success" ? <p aria-live="polite" className="flex items-start gap-2 text-xs leading-6 text-coral"><CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0" />{state.message}</p> : null}
      <button className="flex h-13 w-full items-center justify-center gap-2 rounded-2xl bg-harbor px-5 text-sm font-bold text-white transition hover:bg-tide disabled:cursor-not-allowed disabled:opacity-60" disabled={pending} type="submit">{pending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin" /> : <ArrowLeft aria-hidden="true" className="size-4" />}إنشاء المؤسسة وفتح مساحة العمل</button>
    </form>
  );
}
