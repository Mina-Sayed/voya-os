import { Building2, CircleAlert, ShieldCheck } from "lucide-react";
import { redirect } from "next/navigation";
import { OnboardingForm } from "@/features/organizations/onboarding-form";
import { loadActiveWorkspaceMemberships, loadMfaAssurance } from "@/features/auth/workspace-context";
import { createOrganizationAction } from "./actions";

export default async function OnboardingPage() {
  const memberships = await loadActiveWorkspaceMemberships();
  if (memberships.state === "signed_out") redirect("/sign-in");
  if (memberships.memberships.length > 0) redirect("/workspace");

  const assurance = await loadMfaAssurance();
  if (assurance.state === "required") redirect("/security/mfa?reason=enrollment");

  return (
    <main className="grid min-h-screen place-items-center bg-canvas p-5 text-ink">
      <section className="w-full max-w-2xl rounded-[2rem] border border-line bg-surface p-7 shadow-[0_24px_70px_rgba(16,33,38,0.08)] sm:p-10">
        <div className="flex items-start gap-4">
          <div className="grid size-12 shrink-0 place-items-center rounded-2xl bg-sea-glass/45 text-tide"><Building2 aria-hidden="true" className="size-6" /></div>
          <div><p className="text-xs font-bold text-tide">إعداد المؤسسة</p><h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor">ابدأ مساحة تشغيل شركتك</h1><p className="mt-3 text-sm leading-7 text-muted">أكمل بيانات المؤسسة أولًا. لن يتم فتح بيانات التشغيل قبل تثبيت المؤسسة وMFA.</p></div>
        </div>
        <div className="mt-7 flex gap-3 rounded-2xl border border-line bg-canvas p-4 text-xs leading-6 text-muted"><ShieldCheck aria-hidden="true" className="mt-1 size-4 shrink-0 text-tide" />سيصبح حسابك Owner للمؤسسة، ويمكنك دعوة Manager أو Owner آخر قبل أول موافقة تشغيلية.</div>
        <OnboardingForm action={createOrganizationAction} />
        <p className="mt-6 flex gap-2 text-xs leading-6 text-muted"><CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0 text-coral" />العملة الافتراضية تُقفل بعد أول حجز مؤكد.</p>
      </section>
    </main>
  );
}
