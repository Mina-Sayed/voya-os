import {
  Bell,
  Building2,
  CalendarDays,
  ChevronLeft,
  CircleCheck,
  Clock3,
  Home,
  KeyRound,
  LayoutDashboard,
  MoreHorizontal,
  Settings2,
  ShieldCheck,
  Sparkles,
  UsersRound,
  WalletCards,
} from "lucide-react";
import type { DashboardData, DashboardMetric } from "./dashboard-data";

type OperationsDashboardProps = Readonly<{ data: DashboardData }>;

const navigation = [
  { label: "نظرة عامة", icon: LayoutDashboard, active: true },
  { label: "الإقامات", icon: CalendarDays, active: false },
  { label: "العقارات", icon: Home, active: false },
  { label: "العملاء", icon: UsersRound, active: false },
  { label: "الماليات", icon: WalletCards, active: false },
];

const metricTone: Record<DashboardMetric["tone"], string> = {
  teal: "border-tide/15 bg-[#eef8f4] text-tide",
  sand: "border-[#d9cba7] bg-[#fbf6e9] text-[#7e6731]",
  coral: "border-coral/15 bg-[#fff2ef] text-coral",
};

function NavItem({ active, icon: Icon, label }: (typeof navigation)[number]) {
  return (
    <a
      className={`group flex items-center gap-3 rounded-2xl px-3 py-3 text-sm font-medium transition-colors ${
        active
          ? "bg-sea-glass/35 text-harbor shadow-[inset_0_0_0_1px_rgba(30,125,120,0.12)]"
          : "text-[#b7c6c2] hover:bg-white/7 hover:text-white"
      }`}
      href="#نظرة-عامة"
    >
      <Icon aria-hidden="true" className="size-[18px] shrink-0" strokeWidth={1.8} />
      <span>{label}</span>
      {active ? <span className="mr-auto size-1.5 rounded-full bg-tide" /> : null}
    </a>
  );
}

function MetricCard({ metric }: Readonly<{ metric: DashboardMetric }>) {
  return (
    <article className="rounded-[1.4rem] border border-line bg-surface p-4 shadow-[0_10px_28px_rgba(16,33,38,0.035)]">
      <p className="text-xs font-medium text-muted">{metric.label}</p>
      <div className="mt-4 flex items-end justify-between gap-3">
        <strong className="font-mono text-3xl font-medium tracking-[-0.08em] text-ink">
          {metric.value}
        </strong>
        <span className={`rounded-full border px-2.5 py-1 text-[10px] font-semibold ${metricTone[metric.tone]}`}>
          {metric.change}
        </span>
      </div>
    </article>
  );
}

export function OperationsDashboard({ data }: OperationsDashboardProps) {
  return (
    <div className="min-h-screen bg-canvas p-2 text-ink sm:p-4 lg:p-5">
      <div className="mx-auto flex min-h-[calc(100vh-1rem)] max-w-[1680px] overflow-hidden rounded-[2rem] border border-[#d9ded8] bg-surface shadow-[0_24px_80px_rgba(16,33,38,0.08)] lg:min-h-[calc(100vh-2.5rem)]">
        <aside className="hidden w-[264px] shrink-0 flex-col bg-harbor px-4 py-5 text-white lg:flex">
          <div className="flex items-center gap-3 px-2">
            <div className="grid size-10 place-items-center rounded-2xl bg-sea-glass text-harbor shadow-[0_8px_20px_rgba(169,221,208,0.18)]">
              <KeyRound aria-hidden="true" className="size-5" strokeWidth={2.2} />
            </div>
            <div>
              <p className="text-lg font-bold tracking-[-0.08em]">فُويا</p>
              <p className="mt-0.5 text-[10px] tracking-[0.12em] text-[#9cb5af]">VOYA OS</p>
            </div>
          </div>

          <nav aria-label="التنقل الرئيسي" className="mt-10 space-y-1">
            <p className="mb-3 px-3 text-[10px] font-semibold tracking-[0.08em] text-[#78938c]">مساحة العمل</p>
            {navigation.map((item) => <NavItem key={item.label} {...item} />)}
          </nav>

          <div className="mt-auto rounded-[1.35rem] border border-white/10 bg-white/5 p-3.5">
            <div className="flex items-center gap-2 text-sea-glass">
              <ShieldCheck aria-hidden="true" className="size-4" />
              <p className="text-xs font-semibold">تشغيل مضبوط</p>
            </div>
            <p className="mt-2 text-[11px] leading-6 text-[#b7c6c2]">هذه الواجهة تعرض مؤشرات تجريبية فقط. لا توجد إجراءات تشغيلية مفعّلة.</p>
          </div>
          <a className="mt-4 flex items-center gap-3 rounded-2xl px-3 py-3 text-sm text-[#b7c6c2] transition-colors hover:bg-white/7 hover:text-white" href="#الإعدادات">
            <Settings2 aria-hidden="true" className="size-[18px]" />
            الإعدادات
          </a>
        </aside>

        <main className="min-w-0 flex-1" id="نظرة-عامة">
          <header className="flex flex-wrap items-center justify-between gap-4 border-b border-line px-5 py-4 sm:px-8 lg:px-10">
            <div className="flex items-center gap-3 lg:hidden">
              <div className="grid size-9 place-items-center rounded-xl bg-harbor text-sea-glass"><KeyRound aria-hidden="true" className="size-[17px]" /></div>
              <span className="font-bold tracking-[-0.08em]">فُويا</span>
            </div>
            <div className="hidden items-center gap-2 text-xs text-muted sm:flex">
              <Building2 aria-hidden="true" className="size-4 text-tide" />
              <span>{data.organizationName}</span><span aria-hidden="true" className="text-line">/</span><span className="text-ink">لوحة العمليات</span>
            </div>
            <div className="mr-auto flex items-center gap-2 sm:mr-0">
              <button aria-label="التنبيهات" className="relative grid size-10 place-items-center rounded-xl border border-line text-muted transition-colors hover:border-tide hover:text-tide" type="button">
                <Bell aria-hidden="true" className="size-[18px]" /><span className="absolute left-2 top-2 size-1.5 rounded-full bg-coral" />
              </button>
              <button className="flex items-center gap-2 rounded-xl border border-line p-1.5 pl-3 text-right transition-colors hover:border-tide" type="button">
                <span className="grid size-7 place-items-center rounded-lg bg-harbor text-[10px] font-bold text-sea-glass">لأ</span><span className="hidden text-xs font-semibold sm:block">{data.operatorName}</span>
              </button>
            </div>
          </header>

          <div className="px-5 py-7 sm:px-8 lg:px-10 lg:py-9">
            <div className="flex flex-wrap items-end justify-between gap-5">
              <div>
                <div className="flex items-center gap-2 text-xs text-tide"><span className="size-2 rounded-full bg-tide shadow-[0_0_0_4px_rgba(30,125,120,0.12)]" /><span>{data.dateLabel}</span></div>
                <h1 className="mt-3 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">صباحك منظّم</h1>
                <p className="mt-2 max-w-xl text-sm leading-7 text-muted">نظرة واحدة على الإقامات القادمة والقرارات التي تحتاج فريقك اليوم.</p>
              </div>
              <div className="flex items-center gap-2 rounded-xl border border-[#e4d8bd] bg-[#fff9ed] px-3 py-2 text-[11px] font-semibold text-[#7a6431]"><Sparkles aria-hidden="true" className="size-4" />بيانات تجريبية للعرض فقط</div>
            </div>

            <section aria-label="مؤشرات اليوم" className="mt-7 grid gap-3 md:grid-cols-3">
              {data.metrics.map((metric) => <MetricCard key={metric.label} metric={metric} />)}
            </section>

            <section aria-labelledby="stay-ribbon-heading" className="mt-7 overflow-hidden rounded-[1.6rem] border border-[#d4dfda] bg-[#f0f7f4]">
              <div className="flex flex-wrap items-center justify-between gap-4 border-b border-[#d4dfda] px-5 py-4">
                <div><div className="flex items-center gap-2 text-tide"><CalendarDays aria-hidden="true" className="size-4" /><p className="text-[11px] font-semibold">خط الإقامات</p></div><h2 id="stay-ribbon-heading" className="mt-1 text-lg font-bold tracking-[-0.07em] text-harbor">حركة الأيام القريبة</h2></div>
                <span className="font-mono text-[10px] text-muted ltr">JUL 21 — JUL 27</span>
              </div>
              <ol aria-label="إقامات الأيام القادمة" className="grid gap-px bg-[#d4dfda] md:grid-cols-3">
                {data.bookings.map((booking, index) => (
                  <li className="group relative min-h-40 bg-[#f0f7f4] p-5" key={booking.id}>
                    <span className={`absolute right-0 top-0 h-full w-1.5 ${booking.status === "confirmed" ? "bg-tide" : "bg-coral"}`} />
                    <span className="font-mono text-[10px] text-muted ltr">0{index + 1}</span>
                    <div className="mt-5 flex items-start justify-between gap-3"><div><h3 className="text-sm font-bold tracking-[-0.05em] text-harbor">{booking.property}</h3><p className="mt-1 text-xs text-muted">{booking.guest}</p></div><span className={`shrink-0 rounded-full px-2 py-1 text-[10px] font-semibold ${booking.status === "confirmed" ? "bg-sea-glass/50 text-tide" : "bg-[#fee1db] text-coral"}`}>{booking.status === "confirmed" ? "مؤكدة" : "بانتظار قرار"}</span></div>
                    <div className="mt-5 flex items-center justify-between border-t border-[#d4dfda] pt-3 text-[11px] text-muted"><span>{booking.stayLabel}</span><span className="font-mono ltr">{booking.checkIn.slice(5).replace("-", "/")} → {booking.checkOut.slice(5).replace("-", "/")}</span></div>
                  </li>
                ))}
              </ol>
            </section>

            <div className="mt-7 grid gap-7 xl:grid-cols-[minmax(0,1fr)_360px]">
              <section aria-labelledby="arrivals-heading" className="rounded-[1.6rem] border border-line bg-surface p-5 shadow-[0_10px_28px_rgba(16,33,38,0.03)] sm:p-6">
                <div className="flex items-center justify-between gap-3"><div><p className="text-[11px] font-semibold text-tide">وصولات اليوم</p><h2 id="arrivals-heading" className="mt-1 text-xl font-bold tracking-[-0.07em] text-harbor">جاهزون لتسليم المفاتيح</h2></div><button aria-label="المزيد من خيارات الوصول" className="grid size-9 place-items-center rounded-lg text-muted transition-colors hover:bg-canvas hover:text-harbor" type="button"><MoreHorizontal aria-hidden="true" className="size-5" /></button></div>
                <div className="mt-5 overflow-x-auto"><table className="w-full min-w-[540px] border-separate border-spacing-0 text-right"><thead><tr className="text-[10px] font-semibold text-muted"><th className="border-b border-line pb-3 pr-0">الضيف</th><th className="border-b border-line pb-3">العقار</th><th className="border-b border-line pb-3">الوصول</th><th className="border-b border-line pb-3 pl-0">الحالة</th></tr></thead><tbody>{data.bookings.map((booking) => <tr key={booking.id} className="text-xs"><td className="border-b border-line py-4 font-semibold text-harbor">{booking.guest}</td><td className="border-b border-line py-4 text-muted">{booking.property}</td><td className="border-b border-line py-4 font-mono text-[11px] text-muted ltr">{booking.checkIn}</td><td className="border-b border-line py-4 pl-0"><span className={`inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-[10px] font-semibold ${booking.status === "confirmed" ? "bg-[#edf8f4] text-tide" : "bg-[#fff2ef] text-coral"}`}>{booking.status === "confirmed" ? <CircleCheck aria-hidden="true" className="size-3" /> : <Clock3 aria-hidden="true" className="size-3" />}{booking.status === "confirmed" ? "مؤكدة" : "قيد المراجعة"}</span></td></tr>)}</tbody></table></div>
              </section>

              <section aria-labelledby="approvals-heading" className="rounded-[1.6rem] bg-harbor p-5 text-white shadow-[0_16px_36px_rgba(17,43,50,0.16)] sm:p-6">
                <div className="flex items-start justify-between gap-3"><div><p className="text-[11px] font-semibold text-sea-glass">بانتظارك</p><h2 id="approvals-heading" className="mt-1 text-xl font-bold tracking-[-0.07em]">قرارات تحتاج مراجعة</h2></div><span className="grid size-8 place-items-center rounded-lg bg-white/10 font-mono text-xs text-sea-glass">{data.approvals.length}</span></div>
                <ul className="mt-5 divide-y divide-white/10">{data.approvals.map((approval) => <li className="py-4 first:pt-0" key={approval.id}><div className="flex items-start gap-3"><span className={`mt-1 size-2 shrink-0 rounded-full ${approval.urgency === "attention" ? "bg-coral shadow-[0_0_0_4px_rgba(216,94,77,0.18)]" : "bg-sea-glass"}`} /><div className="min-w-0 flex-1"><p className="text-xs font-bold">{approval.title}</p><p className="mt-1 text-[11px] leading-5 text-[#b7c6c2]">{approval.detail}</p><div className="mt-2 flex items-center justify-between gap-3 text-[10px] text-[#8eaaa3]"><span>{approval.requestedBy}</span><span>{approval.requestedAt}</span></div></div></div></li>)}</ul>
                <button className="mt-4 flex w-full items-center justify-center gap-2 rounded-xl bg-sea-glass px-4 py-3 text-xs font-bold text-harbor transition-colors hover:bg-white" type="button">عرض قائمة القرارات<ChevronLeft aria-hidden="true" className="size-4" /></button>
              </section>
            </div>
          </div>
        </main>
      </div>
    </div>
  );
}
