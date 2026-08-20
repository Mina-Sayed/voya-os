import { Activity, CircleAlert, CircleCheck, FileText, ShieldCheck } from "lucide-react";
import Link from "next/link";

export type AuditActivityItem = Readonly<{
  id: string;
  action: string;
  resourceType: string;
  resourceId: string | null;
  actorType: string;
  actorMembershipId: string | null;
  actorDisplayName: string;
  outcome: "success" | "denied" | "error";
  reasonCode: string | null;
  beforeDelta: Record<string, unknown> | null;
  afterDelta: Record<string, unknown> | null;
  createdAt: string;
}>;

export type AuditActivityFilters = Readonly<{
  from: string;
  to: string;
  actorMembershipId: string;
  action: string;
  resourceType: string;
}>;

export type AuditMemberOption = Readonly<{
  id: string;
  displayName: string;
  role: string;
  status: string;
}>;

const actionCopy: Record<string, string> = {
  "availability_block.created": "إضافة حظر توفر",
  "booking.approval_requested": "طلب موافقة على إقامة",
  "booking.approved": "اعتماد إقامة",
  "booking.confirmed": "تأكيد إقامة",
  "booking.draft_created": "إنشاء مسودة حجز",
  "booking.rejected": "رفض إقامة",
  "client.created": "إضافة عميل",
  "member.invitation_created": "دعوة عضو",
  "member.role_changed": "تغيير دور عضو",
  "member.suspended": "تعليق عضو",
  "operations.task.overdue": "تأخر مهمة تشغيل",
  "property.created": "إضافة عقار",
  "property.updated": "تعديل عقار",
  "property_owner.created": "إضافة مالك عقار",
  "transport.assigned": "تعيين تحويل",
};

const roleCopy: Record<string, string> = {
  accountant: "محاسبة",
  manager: "مدير",
  operations: "تشغيل",
  operator: "تشغيل",
  owner: "مالك المؤسسة",
  sales_agent: "مبيعات",
  viewer: "مشاهد",
};

const outcomeCopy = {
  success: { label: "نجح", Icon: CircleCheck, tone: "text-tide bg-[#edf8f4]" },
  denied: { label: "مرفوض", Icon: CircleAlert, tone: "text-coral bg-[#fff0eb]" },
  error: { label: "تعذر", Icon: CircleAlert, tone: "text-coral bg-[#fff0eb]" },
} as const;

function formatDate(value: string) {
  return new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
}

function formatDelta(value: Record<string, unknown> | null) {
  return value ? JSON.stringify(value, null, 2) : "لا توجد تغييرات مسجلة";
}

function FilterField({ label, name, value, placeholder, type = "text" }: Readonly<{ label: string; name: string; value: string; placeholder?: string; type?: "date" | "text" }>) {
  return (
    <label className="block">
      <span className="mb-2 block text-[11px] font-bold text-tide">{label}</span>
      <input className="min-h-11 w-full rounded-xl border border-line bg-white px-3 text-sm text-ink outline-none transition focus:border-tide focus:ring-2 focus:ring-sea-glass" defaultValue={value} name={name} placeholder={placeholder} type={type} />
    </label>
  );
}

function SelectField({ label, name, value, members }: Readonly<{ label: string; name: string; value: string; members: readonly AuditMemberOption[] }>) {
  return (
    <label className="block">
      <span className="mb-2 block text-[11px] font-bold text-tide">{label}</span>
      <select className="min-h-11 w-full rounded-xl border border-line bg-white px-3 text-sm text-ink outline-none transition focus:border-tide focus:ring-2 focus:ring-sea-glass" defaultValue={value} name={name}>
        <option value="">كل الأعضاء</option>
        {members.map((member) => <option key={member.id} value={member.id}>{member.displayName} — {roleCopy[member.role] ?? member.role}{member.status !== "active" ? " (معلق)" : ""}</option>)}
      </select>
    </label>
  );
}

export function AuditActivityPage({ events, filters, members }: Readonly<{ events: readonly AuditActivityItem[]; filters: AuditActivityFilters; members: readonly AuditMemberOption[] }>) {
  return (
    <main className="min-h-[calc(100vh-74px)] bg-canvas px-4 py-5 text-ink sm:px-8 sm:py-8 lg:px-12">
      <div className="mx-auto max-w-5xl">
        <header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9">
          <div className="flex flex-wrap items-start justify-between gap-5">
            <div className="flex gap-4">
              <div className="grid size-12 place-items-center rounded-2xl bg-harbor text-sea-glass"><Activity aria-hidden="true" className="size-6" /></div>
              <div><p className="text-[11px] font-bold tracking-[0.08em] text-tide">دليل المساءلة</p><h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">سجل النشاط</h1><p className="mt-3 max-w-xl text-sm leading-7 text-muted">فلترة آمنة للأفعال والنتائج والتغييرات المسجلة. التفاصيل المعروضة مقيدة بالمؤسسة والصلاحية.</p></div>
            </div>
            <div className="flex items-center gap-2 rounded-xl border border-[#d4dfda] bg-white/70 px-3 py-2 text-[11px] font-semibold text-tide"><ShieldCheck aria-hidden="true" className="size-4" />مقيد بالصلاحية</div>
          </div>
        </header>

        <section aria-labelledby="audit-filters-heading" className="mt-6 rounded-[1.75rem] border border-line bg-surface p-5 shadow-[0_8px_22px_rgba(16,33,38,0.03)] sm:p-6">
          <div className="flex flex-wrap items-end justify-between gap-3"><div><p className="text-[11px] font-bold text-tide">استعلام مقيد</p><h2 className="mt-2 text-xl font-extrabold tracking-[-0.06em] text-harbor" id="audit-filters-heading">تصفية سجل النشاط</h2></div><span className="text-[11px] text-muted">حتى 100 حدث في كل قراءة</span></div>
          <form className="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3" method="get">
            <FilterField label="من تاريخ" name="from" type="date" value={filters.from} />
            <FilterField label="إلى تاريخ" name="to" type="date" value={filters.to} />
            <SelectField label="العضو المنفذ" members={members} name="member" value={filters.actorMembershipId} />
            <FilterField label="الفعل" name="action" placeholder="مثال: property.updated" value={filters.action} />
            <FilterField label="نوع المورد" name="resource" placeholder="مثال: property" value={filters.resourceType} />
            <div className="flex items-end gap-2"><button className="min-h-11 flex-1 rounded-xl bg-harbor px-4 text-sm font-bold text-white transition hover:bg-[#204e43]" type="submit">تطبيق الفلتر</button><Link className="inline-flex min-h-11 items-center rounded-xl border border-line px-4 text-sm font-bold text-tide transition hover:bg-sea-glass/40" href="/workspace/activity">مسح</Link></div>
          </form>
        </section>

        {events.length === 0 ? <section className="mt-6 rounded-[1.75rem] border border-dashed border-[#bfd1cb] bg-surface px-6 py-14 text-center"><Activity aria-hidden="true" className="mx-auto size-6 text-tide" /><h2 className="mt-5 text-xl font-bold text-harbor">لا توجد أحداث مرئية ضمن الفلاتر والصلاحيات</h2><p className="mt-2 text-sm text-muted">جرّب إزالة بعض الفلاتر أو وسّع النطاق الزمني.</p></section> : <section aria-label="أحداث النشاط" className="mt-6 space-y-3">{events.map((event) => { const outcome = outcomeCopy[event.outcome]; const OutcomeIcon = outcome.Icon; return <article className="rounded-[1.4rem] border border-line bg-surface p-4 shadow-[0_8px_22px_rgba(16,33,38,0.03)]" key={event.id}><div className="flex items-start gap-4"><div className={`grid size-9 shrink-0 place-items-center rounded-xl ${outcome.tone}`}><OutcomeIcon aria-hidden="true" className="size-4" /></div><div className="min-w-0 flex-1"><h2 className="truncate text-sm font-bold text-harbor">{actionCopy[event.action] ?? event.action}</h2><p className="mt-1 text-[11px] text-muted">{event.resourceType} · {event.actorDisplayName}</p></div><div className="shrink-0 text-end"><span className={`inline-flex rounded-full px-2 py-1 text-[10px] font-bold ${outcome.tone}`}>{outcome.label}</span><time className="mt-1 block font-mono text-[10px] text-muted" dateTime={event.createdAt}>{formatDate(event.createdAt)}</time></div></div><details className="mt-4 border-t border-line pt-3"><summary className="flex min-h-11 cursor-pointer list-none items-center gap-2 text-xs font-bold text-tide"><FileText aria-hidden="true" className="size-4" />تفاصيل الحدث</summary><dl className="mt-3 grid gap-3 text-xs sm:grid-cols-2"><div><dt className="text-muted">الفاعل</dt><dd className="mt-1 font-semibold text-harbor">{event.actorDisplayName} ({event.actorType})</dd></div><div><dt className="text-muted">نوع المورد</dt><dd className="mt-1 font-semibold text-harbor">{event.resourceType}</dd></div><div><dt className="text-muted">معرف المورد</dt><dd className="mt-1 break-all font-mono text-[11px] text-harbor" dir="ltr">{event.resourceId ?? "غير متاح"}</dd></div><div><dt className="text-muted">رمز السبب</dt><dd className="mt-1 font-mono text-[11px] text-harbor" dir="ltr">{event.reasonCode ?? "غير مسجل"}</dd></div></dl><div className="mt-4 grid gap-3 lg:grid-cols-2"><div><p className="text-[11px] font-bold text-muted">قبل التغيير</p><pre className="mt-2 max-h-48 overflow-auto rounded-xl bg-[#f5f7f3] p-3 font-mono text-[11px] leading-5 text-harbor" dir="ltr">{formatDelta(event.beforeDelta)}</pre></div><div><p className="text-[11px] font-bold text-muted">بعد التغيير</p><pre className="mt-2 max-h-48 overflow-auto rounded-xl bg-[#f5f7f3] p-3 font-mono text-[11px] leading-5 text-harbor" dir="ltr">{formatDelta(event.afterDelta)}</pre></div></div></details></article>; })}</section>}
      </div>
    </main>
  );
}
