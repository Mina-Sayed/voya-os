import { CircleUserRound, ShieldCheck, UserRoundPlus } from "lucide-react";
import { ClientCreateForm, type ClientCreateAction } from "./client-create-form";

export type ClientListItem = Readonly<{ id: string; displayName: string; createdAt: string }>;

function formatCreatedAt(createdAt: string) {
  return new Intl.DateTimeFormat("ar-EG", { day: "numeric", month: "short", year: "numeric" }).format(new Date(createdAt));
}

export function ClientsPage({ clients, createClient }: Readonly<{ clients: readonly ClientListItem[]; createClient?: ClientCreateAction }>) {
  return (
    <main className="min-h-screen bg-canvas px-4 py-5 text-ink sm:px-8 sm:py-8 lg:px-12">
      <div className="mx-auto max-w-5xl">
        <header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9">
          <div className="flex flex-wrap items-start justify-between gap-5"><div className="flex gap-4"><div className="grid size-12 shrink-0 place-items-center rounded-2xl bg-harbor text-sea-glass shadow-[0_10px_22px_rgba(17,43,50,0.14)]"><CircleUserRound aria-hidden="true" className="size-6" /></div><div><p className="text-[11px] font-bold tracking-[0.08em] text-tide">سجل العملاء الأساسي</p><h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">العملاء</h1><p className="mt-3 max-w-2xl text-sm leading-7 text-muted">مرجع محدود للاسم وسجل الإنشاء. لا تظهر بيانات الاتصال في هذه المرحلة. ستُضاف إدارة leads بعقد خصوصية مستقل.</p></div></div><div className="flex items-center gap-2 rounded-xl border border-[#d4dfda] bg-white/70 px-3 py-2 text-[11px] font-semibold text-tide"><ShieldCheck aria-hidden="true" className="size-4" />بيانات محدودة ومحمية</div></div>
          <div className="mt-7 flex items-end gap-3 border-t border-[#d4dfda] pt-5"><strong className="font-mono text-4xl font-medium tracking-[-0.09em] text-harbor">{clients.length}</strong><span className="pb-1 text-xs text-muted">عميل مسجل</span></div>
        </header>
        {createClient ? <div className="mt-6"><ClientCreateForm createClient={createClient} /></div> : null}
        {clients.length === 0 ? <section className="mt-6 rounded-[1.75rem] border border-dashed border-[#bfd1cb] bg-surface px-6 py-14 text-center sm:px-10"><div className="mx-auto grid size-12 place-items-center rounded-2xl bg-[#edf8f4] text-tide"><UserRoundPlus aria-hidden="true" className="size-5" /></div><h2 className="mt-5 text-xl font-bold tracking-[-0.07em] text-harbor">لا يوجد عملاء مسجلون بعد</h2><p className="mx-auto mt-2 max-w-md text-sm leading-7 text-muted">أضف الاسم فقط الآن؛ حقول الاتصال والخصوصية ستتبع سياسة معتمدة.</p></section> : <section aria-label="سجل العملاء" className="mt-6 grid gap-3 sm:grid-cols-2">{clients.map((client) => <article className="relative overflow-hidden rounded-[1.5rem] border border-line bg-surface p-5 shadow-[0_10px_28px_rgba(16,33,38,0.035)]" key={client.id}><span className="absolute right-0 top-0 h-full w-1.5 bg-tide" /><p className="text-[10px] font-semibold tracking-[0.08em] text-muted">عميل مسجل</p><h2 className="mt-2 truncate text-lg font-bold tracking-[-0.06em] text-harbor">{client.displayName}</h2><div className="mt-6 flex justify-between border-t border-line pt-3 text-[11px] text-muted"><span>تاريخ الإضافة</span><time className="font-mono text-[10px] text-ink" dateTime={client.createdAt}>{formatCreatedAt(client.createdAt)}</time></div></article>)}</section>}
      </div>
    </main>
  );
}
