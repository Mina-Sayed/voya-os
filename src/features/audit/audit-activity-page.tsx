import { Activity, CircleAlert, CircleCheck, ShieldCheck } from "lucide-react";

export type AuditActivityItem = Readonly<{ id: string; action: string; resourceType: string; outcome: "success" | "denied" | "error"; createdAt: string }>;

const actionCopy: Record<string, string> = {
  "availability_block.created": "إضافة حظر توفر",
  "booking.draft_created": "إنشاء مسودة حجز",
  "client.created": "إضافة عميل",
  "property.created": "إضافة عقار",
  "property_owner.created": "إضافة مالك عقار",
};
const outcomeCopy = { success: { label: "نجح", Icon: CircleCheck, tone: "text-tide bg-[#edf8f4]" }, denied: { label: "مرفوض", Icon: CircleAlert, tone: "text-coral bg-[#fff0eb]" }, error: { label: "تعذر", Icon: CircleAlert, tone: "text-coral bg-[#fff0eb]" } } as const;
function formatDate(value: string) { return new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)); }

export function AuditActivityPage({ events }: Readonly<{ events: readonly AuditActivityItem[] }>) {
  return <main className="min-h-screen bg-canvas px-4 py-5 text-ink sm:px-8 sm:py-8 lg:px-12"><div className="mx-auto max-w-4xl"><header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9"><div className="flex flex-wrap items-start justify-between gap-5"><div className="flex gap-4"><div className="grid size-12 place-items-center rounded-2xl bg-harbor text-sea-glass"><Activity aria-hidden="true" className="size-6" /></div><div><p className="text-[11px] font-bold tracking-[0.08em] text-tide">دليل المساءلة</p><h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">سجل النشاط</h1><p className="mt-3 max-w-xl text-sm leading-7 text-muted">عرض مختصر للأفعال والنتائج فقط. لا يعرض تفاصيل الطلبات أو التغييرات الداخلية.</p></div></div><div className="flex items-center gap-2 rounded-xl border border-[#d4dfda] bg-white/70 px-3 py-2 text-[11px] font-semibold text-tide"><ShieldCheck aria-hidden="true" className="size-4" />مقيد بالصلاحية</div></div></header>{events.length === 0 ? <section className="mt-6 rounded-[1.75rem] border border-dashed border-[#bfd1cb] bg-surface px-6 py-14 text-center"><Activity aria-hidden="true" className="mx-auto size-6 text-tide" /><h2 className="mt-5 text-xl font-bold text-harbor">لا توجد أحداث مرئية ضمن صلاحياتك</h2></section> : <section aria-label="أحداث النشاط" className="mt-6 space-y-3">{events.map((event) => { const outcome = outcomeCopy[event.outcome]; const OutcomeIcon = outcome.Icon; return <article className="flex items-center gap-4 rounded-[1.4rem] border border-line bg-surface p-4 shadow-[0_8px_22px_rgba(16,33,38,0.03)]" key={event.id}><div className={`grid size-9 shrink-0 place-items-center rounded-xl ${outcome.tone}`}><OutcomeIcon aria-hidden="true" className="size-4" /></div><div className="min-w-0 flex-1"><h2 className="truncate text-sm font-bold text-harbor">{actionCopy[event.action] ?? event.action}</h2><p className="mt-1 text-[11px] text-muted">{event.resourceType}</p></div><div className="shrink-0 text-end"><span className={`inline-flex rounded-full px-2 py-1 text-[10px] font-bold ${outcome.tone}`}>{outcome.label}</span><time className="mt-1 block font-mono text-[10px] text-muted" dateTime={event.createdAt}>{formatDate(event.createdAt)}</time></div></article>; })}</section>}</div></main>;
}
