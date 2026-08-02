import {
  ArrowLeft,
  ArrowUpLeft,
  Building2,
  CircleAlert,
  CircleCheck,
  Clock3,
  Plus,
  RadioTower,
  Sparkles,
  UsersRound,
} from "lucide-react";
import Link from "next/link";
import type { DashboardData, DashboardMetric } from "./dashboard-data";

type OperationsDashboardProps = Readonly<{ data: DashboardData }>;

export type DashboardNavigationItem = Readonly<{
  label: string;
  href?: string;
  disabledReason?: string;
}>;

export const dashboardNavigationItems: readonly DashboardNavigationItem[] = [
  { label: "نظرة عامة", href: "/workspace" },
  { label: "الإقامات", href: "/workspace/bookings" },
  { label: "العقارات", href: "/workspace/properties" },
  { label: "العملاء", href: "/workspace/clients" },
  { label: "العملاء المحتملون", href: "/workspace/leads" },
];

const metricTone: Record<DashboardMetric["tone"], string> = {
  teal: "border-[#cfe3d9] bg-[#eef7f2] text-[#1a6958]",
  sand: "border-[#e4d3ae] bg-[#fff8e9] text-[#85652e]",
  coral: "border-[#f0c9bd] bg-[#fff1ed] text-[#a84b3c]",
};

const sourceCopy: Record<string, string> = { website: "الموقع", referral: "إحالة", walk_in: "زيارة مباشرة" };
const leadStatusCopy: Record<string, string> = { new: "جديد", qualified: "مؤهل", awaiting_match: "بانتظار المطابقة" };

function MetricCard({ metric }: Readonly<{ metric: DashboardMetric }>) {
  return (
    <article className="rounded-2xl border border-[#e1e5df] bg-white p-5 shadow-[0_10px_24px_rgba(26,52,45,0.035)]">
      <div className="flex items-start justify-between gap-3">
        <p className="text-xs font-bold text-[#6a7c75]">{metric.label}</p>
        <span className={`rounded-full border px-2 py-1 text-[10px] font-bold ${metricTone[metric.tone]}`}>{metric.change}</span>
      </div>
      <strong className="mt-5 block font-mono text-4xl font-medium tracking-[-0.1em] text-[#173d35]">{metric.value}</strong>
    </article>
  );
}

function EmptyState({ title, body, href, action }: Readonly<{ title: string; body: string; href?: string; action?: string }>) {
  return (
    <div className="rounded-2xl border border-dashed border-[#cfd9d2] bg-[#fcfdfb] px-5 py-10 text-center">
      <CircleCheck aria-hidden="true" className="mx-auto size-6 text-[#1a6958]" />
      <h3 className="mt-4 text-base font-extrabold text-[#173d35]">{title}</h3>
      <p className="mx-auto mt-2 max-w-sm text-xs leading-6 text-[#71817b]">{body}</p>
      {href && action ? <Link className="mt-5 inline-flex items-center gap-2 rounded-xl bg-[#173d35] px-4 py-2.5 text-xs font-bold text-white transition hover:bg-[#246b5b]" href={href}>{action}<ArrowLeft aria-hidden="true" className="size-4" /></Link> : null}
    </div>
  );
}

export function OperationsDashboard({ data }: OperationsDashboardProps) {
  return (
    <main className="min-h-[calc(100vh-74px)] px-4 py-6 sm:px-7 sm:py-8 lg:px-9 lg:py-10">
      <div className="mx-auto max-w-[1400px]">
        <header className="flex flex-wrap items-end justify-between gap-6">
          <div>
            <div className="flex items-center gap-2 text-xs font-bold text-[#a2742d]"><span className="size-2 rounded-full bg-[#b88a3a]" />{data.dateLabel}</div>
            <h1 className="mt-3 text-3xl font-extrabold tracking-[-0.09em] text-[#173d35] sm:text-4xl">لوحة التشغيل</h1>
            <p className="mt-2 max-w-2xl text-sm leading-7 text-[#687b74]">رتّب يومك من شاشة واحدة: الطلبات الجديدة، حالة السجل، والقرارات التي تحتاج تدخّل فريقك.</p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <span className={`inline-flex items-center gap-2 rounded-full border px-3 py-2 text-[11px] font-bold ${data.isPreview ? "border-[#e4d3ae] bg-[#fff8e9] text-[#85652e]" : "border-[#cfe3d9] bg-[#eef7f2] text-[#1a6958]"}`}>
              <span className="size-1.5 rounded-full bg-current" />{data.isPreview ? "معاينة تصميم" : "مزامنة المؤسسة مفعّلة"}
            </span>
            <Link className="inline-flex items-center gap-2 rounded-xl bg-[#b88a3a] px-4 py-2.5 text-xs font-extrabold text-white shadow-[0_8px_18px_rgba(184,138,58,0.2)] transition hover:bg-[#9a712d]" href="/workspace/leads"><Plus aria-hidden="true" className="size-4" />إضافة طلب</Link>
          </div>
        </header>

        <section aria-label="مؤشرات المؤسسة" className="mt-8 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          {data.metrics.map((metric) => <MetricCard key={metric.label} metric={metric} />)}
        </section>

        <div className="mt-8 grid gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(320px,0.65fr)]">
          <section aria-labelledby="leads-heading" className="rounded-2xl border border-[#e1e5df] bg-white p-5 shadow-[0_10px_24px_rgba(26,52,45,0.035)] sm:p-6">
            <div className="flex items-start justify-between gap-4">
              <div><div className="flex items-center gap-2 text-[#1a6958]"><RadioTower aria-hidden="true" className="size-4" /><span className="text-[11px] font-bold">خط المبيعات</span></div><h2 className="mt-2 text-xl font-extrabold tracking-[-0.07em] text-[#173d35]" id="leads-heading">آخر الطلبات</h2></div>
              <Link className="inline-flex items-center gap-1 text-xs font-bold text-[#1a6958] hover:text-[#173d35]" href="/workspace/leads">عرض الكل<ArrowLeft aria-hidden="true" className="size-4" /></Link>
            </div>
            <div className="mt-5">
              {data.recentLeads.length === 0 ? <EmptyState action="إضافة أول طلب" body="عند تسجيل طلب جديد سيظهر هنا مع مصدره وحالته وتاريخ المتابعة." href="/workspace/leads" title="لا توجد طلبات بعد" /> : (
                <div className="overflow-x-auto"><table className="w-full min-w-[620px] border-separate border-spacing-0 text-right"><thead><tr className="text-[10px] font-bold text-[#7a8983]"><th className="border-b border-[#e6e9e4] pb-3">الطلب</th><th className="border-b border-[#e6e9e4] pb-3">المصدر</th><th className="border-b border-[#e6e9e4] pb-3">الفترة</th><th className="border-b border-[#e6e9e4] pb-3">الحالة</th><th className="border-b border-[#e6e9e4] pb-3" /></tr></thead><tbody>{data.recentLeads.map((lead) => <tr className="text-xs" key={lead.id}><td className="border-b border-[#eef0ec] py-4 font-bold text-[#173d35]">{lead.title}</td><td className="border-b border-[#eef0ec] py-4 text-[#6b7d76]">{sourceCopy[lead.source] ?? lead.source}</td><td className="border-b border-[#eef0ec] py-4 font-mono text-[10px] text-[#6b7d76]" dir="ltr">{lead.requestedCheckIn && lead.requestedCheckOut ? `${lead.requestedCheckIn.slice(5)} → ${lead.requestedCheckOut.slice(5)}` : "غير محددة"}</td><td className="border-b border-[#eef0ec] py-4"><span className="inline-flex items-center gap-1.5 rounded-full bg-[#eef7f2] px-2.5 py-1 text-[10px] font-bold text-[#1a6958]"><Clock3 aria-hidden="true" className="size-3" />{leadStatusCopy[lead.status] ?? lead.status}</span></td><td className="border-b border-[#eef0ec] py-4 text-left"><Link aria-label={`فتح ${lead.title}`} className="inline-grid size-8 place-items-center rounded-lg text-[#82918b] transition hover:bg-[#eef7f2] hover:text-[#1a6958]" href="/workspace/leads"><ArrowUpLeft aria-hidden="true" className="size-4" /></Link></td></tr>)}</tbody></table></div>
              )}
            </div>
          </section>

          <section aria-labelledby="approvals-heading" className="rounded-2xl bg-[#173d35] p-5 text-white shadow-[0_16px_36px_rgba(23,61,53,0.18)] sm:p-6">
            <div className="flex items-start justify-between gap-3"><div><div className="flex items-center gap-2 text-[#d5e9df]"><Sparkles aria-hidden="true" className="size-4" /><span className="text-[11px] font-bold">حالة الفريق</span></div><h2 className="mt-2 text-xl font-extrabold tracking-[-0.07em]" id="approvals-heading">قرارات تحتاج مراجعة</h2></div><span className="grid size-9 place-items-center rounded-xl bg-white/10 font-mono text-sm text-[#d5e9df]">{data.approvals.length}</span></div>
            {data.approvals.length === 0 ? <div className="mt-8 rounded-xl border border-white/10 bg-white/5 p-5 text-center"><CircleCheck aria-hidden="true" className="mx-auto size-6 text-[#d5e9df]" /><p className="mt-3 text-sm font-bold">كل القرارات مرتبة</p><p className="mt-1 text-xs leading-6 text-[#aec4bb]">لا توجد طلبات موافقة مرئية ضمن صلاحياتك الآن.</p></div> : <ul className="mt-6 divide-y divide-white/10">{data.approvals.map((approval) => <li className="py-4 first:pt-0" key={approval.id}><div className="flex items-start gap-3"><span className={`mt-1.5 size-2 shrink-0 rounded-full ${approval.urgency === "attention" ? "bg-[#e28a62] shadow-[0_0_0_4px_rgba(226,138,98,0.18)]" : "bg-[#d5e9df]"}`} /><div className="min-w-0 flex-1"><p className="text-xs font-bold">{approval.title}</p><p className="mt-1 text-[11px] leading-5 text-[#aec4bb]">{approval.detail}</p><div className="mt-2 flex items-center justify-between gap-3 text-[10px] text-[#88a79b]"><span>{approval.requestedBy}</span><span>{approval.requestedAt}</span></div></div></div></li>)}</ul>}
            <Link className="mt-5 flex w-full items-center justify-center gap-2 rounded-xl bg-[#d5e9df] px-4 py-3 text-xs font-extrabold text-[#173d35] transition hover:bg-white" href="/workspace/approvals">فتح مسار المراجعة<ArrowLeft aria-hidden="true" className="size-4" /></Link>
          </section>
        </div>

        <section aria-labelledby="quick-actions-heading" className="mt-6 rounded-2xl border border-[#e1e5df] bg-[#f0f6f1] p-5 sm:p-6">
          <div className="flex items-center gap-2 text-[#a2742d]"><CircleAlert aria-hidden="true" className="size-4" /><span className="text-[11px] font-bold">اختصارات آمنة</span></div>
          <h2 className="mt-2 text-xl font-extrabold tracking-[-0.07em] text-[#173d35]" id="quick-actions-heading">ابدأ من الإجراء الذي تحتاجه</h2>
          <div className="mt-5 grid gap-3 sm:grid-cols-3">
            {[
              { href: "/workspace/leads", icon: RadioTower, title: "سجّل طلبًا جديدًا", body: "أضف طلب العميل دون تخمين بيانات غير مقدمة." },
              { href: "/workspace/properties", icon: Building2, title: "راجع العقارات", body: "تأكد من حالة المخزون قبل المطابقة." },
              { href: "/workspace/clients", icon: UsersRound, title: "افتح سجل العملاء", body: "اعمل داخل حدود مؤسستك وبصلاحيتك الحالية." },
            ].map(({ href, icon: Icon, title, body }) => <Link className="group rounded-xl border border-[#d9e4dc] bg-white p-4 transition hover:-translate-y-0.5 hover:border-[#b88a3a]" href={href} key={href}><Icon aria-hidden="true" className="size-5 text-[#1a6958]" /><h3 className="mt-4 text-sm font-extrabold text-[#173d35]">{title}</h3><p className="mt-1 text-xs leading-6 text-[#71817b]">{body}</p><ArrowLeft aria-hidden="true" className="mt-3 size-4 text-[#b88a3a] transition group-hover:-translate-x-1" /></Link>)}
          </div>
        </section>
      </div>
    </main>
  );
}
