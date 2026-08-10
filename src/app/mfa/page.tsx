import { KeyRound, ShieldCheck } from "lucide-react";
import { MfaChallenge } from "@/features/auth/mfa-challenge";

export default function MfaPage() {
  return (
    <main className="grid min-h-screen place-items-center bg-canvas p-5 text-ink">
      <section className="w-full max-w-xl rounded-[2rem] border border-line bg-surface p-7 shadow-[0_24px_70px_rgba(16,33,38,0.08)] sm:p-10">
        <div className="grid size-14 place-items-center rounded-2xl bg-sea-glass/45 text-tide">
          <KeyRound aria-hidden="true" className="size-6" />
        </div>
        <p className="mt-6 text-xs font-bold text-tide">تحقق إضافي</p>
        <h1 className="mt-3 text-3xl font-bold tracking-[-0.09em] text-harbor">أكّد هويتك</h1>
        <p className="mt-4 text-sm leading-7 text-muted">اختر تطبيق المصادقة، ثم أدخل الرمز الحالي المكوّن من ستة أرقام لفتح مساحة العمل المحمية.</p>
        <MfaChallenge />
        <div className="mt-7 flex items-center gap-2 border-t border-line pt-5 text-xs leading-6 text-muted">
          <ShieldCheck aria-hidden="true" className="size-4 shrink-0 text-tide" />
          لا نعرض تفاصيل مزوّد المصادقة أو أخطاءه الداخلية.
        </div>
      </section>
    </main>
  );
}
