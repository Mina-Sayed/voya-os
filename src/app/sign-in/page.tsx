import { BadgeCheck, KeyRound, MailCheck, ShieldCheck } from "lucide-react";
import { SignInForm } from "@/features/auth/sign-in-form";
import { PasswordSignInForm } from "@/features/auth/password-sign-in-form";
import { readSupabasePublicConfig } from "@/lib/supabase/public-config";
import { passwordSignInAction, requestSignInAction } from "./actions";

function hasSignInConfiguration(): boolean {
  try {
    readSupabasePublicConfig(process.env);
    return Boolean(process.env.VOYA_APP_URL?.trim() && process.env.SUPABASE_SERVICE_ROLE_KEY?.trim());
  } catch {
    return false;
  }
}

type SignInPageProps = Readonly<{
  searchParams?: Promise<Readonly<{ error?: string | string[] }>>;
}>;

export default async function SignInPage({ searchParams }: SignInPageProps) {
  const configured = hasSignInConfiguration();
  const error = (await searchParams)?.error;
  const invalidLinkSession = error === "link_session";

  return (
    <main className="min-h-screen bg-canvas px-4 py-5 text-ink sm:grid sm:place-items-center sm:p-8">
      <div className="mx-auto grid w-full max-w-5xl overflow-hidden rounded-[2rem] border border-[#d9ded8] bg-surface shadow-[0_28px_90px_rgba(16,33,38,0.1)] lg:grid-cols-[1.05fr_0.95fr]">
        <section className="relative overflow-hidden bg-harbor px-6 py-8 text-white sm:px-10 sm:py-12">
          <div aria-hidden="true" className="absolute -left-28 top-16 size-72 rounded-full border border-sea-glass/20" />
          <div aria-hidden="true" className="absolute -left-12 top-32 size-40 rounded-full bg-tide/20 blur-2xl" />
          <div className="relative flex min-h-[310px] flex-col">
            <div className="flex items-center gap-3">
              <div className="grid size-11 place-items-center rounded-2xl bg-sea-glass text-harbor shadow-[0_10px_24px_rgba(169,221,208,0.2)]"><KeyRound aria-hidden="true" className="size-5" /></div>
              <div><p className="text-xl font-bold tracking-[-0.08em]">فُويا</p><p className="text-[10px] tracking-[0.16em] text-[#9cb5af]">VOYA OS</p></div>
            </div>
            <div className="my-auto pt-14">
              <p className="text-xs font-semibold text-sea-glass">دخول فريق التشغيل</p>
              <h1 className="mt-3 max-w-md text-4xl font-bold leading-tight tracking-[-0.09em] sm:text-5xl">كل إقامة تبدأ بدخول مضبوط.</h1>
              <p className="mt-5 max-w-sm text-sm leading-7 text-[#c2d0cc]">ادخل برابط آمن يصل إلى بريدك. تظهر مساحة العمل فقط بعد التحقق من عضويتك النشطة.</p>
            </div>
            <div className="relative mt-10 flex items-center gap-3 border-t border-white/10 pt-5 text-xs text-[#b7c6c2]"><ShieldCheck aria-hidden="true" className="size-4 text-sea-glass" />لا يتم إنشاء مؤسسات جديدة من هذه الشاشة.</div>
          </div>
        </section>

        <section className="px-6 py-8 sm:px-10 sm:py-12">
          <div className="flex items-center justify-between gap-4"><p className="rounded-full bg-[#edf8f4] px-3 py-1 text-[11px] font-bold text-tide">مساحة عمل مهيأة</p><BadgeCheck aria-hidden="true" className="size-5 text-tide" /></div>
          <h2 className="mt-8 text-3xl font-bold tracking-[-0.09em] text-harbor">مرحبًا بعودتك</h2>
          <p className="mt-3 max-w-sm text-sm leading-7 text-muted">استخدم بريد العمل المرتبط بعضوية فُويا الخاصة بك.</p>
          {invalidLinkSession ? (
            <p className="mt-5 rounded-2xl border border-[#efc9bd] bg-[#fff4ef] px-4 py-3 text-sm leading-7 text-[#8d3e2c]" role="alert">
              تعذر فتح رابط الدخول في جلسة المتصفح الحالية. افتح أحدث رابط في نفس المتصفح ونفس العنوان الذي طلبته منه: localhost مع localhost أو رابط الإنتاج مع رابط الإنتاج. لا تستخدم رابطًا قديمًا أو تخلط بين localhost و127.0.0.1.
            </p>
          ) : null}
          <PasswordSignInForm configured={configured} onSignIn={passwordSignInAction} />
          <div className="my-7 flex items-center gap-3 text-xs text-muted"><span aria-hidden="true" className="h-px flex-1 bg-line" /><span>أو</span><span aria-hidden="true" className="h-px flex-1 bg-line" /></div>
          <section id="magic-link">
            <h3 className="text-sm font-bold text-harbor">الدخول برابط آمن</h3>
            <SignInForm compact configured={configured} onRequestSignIn={requestSignInAction} />
          </section>
          <div className="mt-8 flex gap-3 border-t border-line pt-5 text-xs leading-6 text-muted"><MailCheck aria-hidden="true" className="mt-0.5 size-4 shrink-0 text-tide" />رابط الدخول صالح لفترة محدودة ويُستخدم لمرة واحدة.</div>
        </section>
      </div>
    </main>
  );
}
