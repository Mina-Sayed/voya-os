import { ArrowRight, Clock3, ShieldCheck } from "lucide-react";
import Link from "next/link";

export default function AccessPendingPage() {
  return (
    <main className="grid min-h-screen place-items-center bg-canvas p-5 text-ink">
      <section className="w-full max-w-xl rounded-[2rem] border border-line bg-surface p-7 text-center shadow-[0_24px_70px_rgba(16,33,38,0.08)] sm:p-10">
        <div className="mx-auto grid size-14 place-items-center rounded-2xl bg-sea-glass/45 text-tide"><Clock3 aria-hidden="true" className="size-6" /></div>
        <p className="mt-6 text-xs font-bold text-tide">التحقق من الوصول</p>
        <h1 className="mt-3 text-3xl font-bold tracking-[-0.09em] text-harbor">لا توجد مساحة عمل متاحة الآن</h1>
        <p className="mx-auto mt-4 max-w-md text-sm leading-7 text-muted">إذا كان لديك دعوة، تأكد من تسجيل الدخول بالبريد المرتبط بها. يمكن لمسؤول المؤسسة مساعدتك في إضافة الوصول.</p>
        <div className="mt-7 flex items-center justify-center gap-2 border-y border-line py-4 text-xs text-muted"><ShieldCheck aria-hidden="true" className="size-4 text-tide" />لا نعرض تفاصيل المؤسسات أو العضويات هنا.</div>
        <Link className="mt-7 inline-flex items-center gap-2 text-sm font-bold text-tide hover:text-harbor" href="/sign-in">العودة إلى الدخول <ArrowRight aria-hidden="true" className="size-4" /></Link>
      </section>
    </main>
  );
}
