import { Building2, CircleCheck, Clock3, MapPinned, ShieldCheck } from "lucide-react";

export type PropertyListItem = Readonly<{
  id: string;
  code: string;
  name: string;
  timezone: string;
  status: "active" | "inactive";
  createdAt: string;
}>;

type PropertiesPageProps = Readonly<{
  properties: readonly PropertyListItem[];
}>;

const statusCopy = {
  active: { label: "نشط", tone: "bg-[#edf8f4] text-tide", Icon: CircleCheck },
  inactive: { label: "غير نشط", tone: "bg-[#f1f0ed] text-muted", Icon: Clock3 },
} as const;

function formatCreatedAt(createdAt: string) {
  return new Intl.DateTimeFormat("ar-EG", { day: "numeric", month: "short", year: "numeric" }).format(new Date(createdAt));
}

export function PropertiesPage({ properties }: PropertiesPageProps) {
  return (
    <main className="min-h-screen bg-canvas px-4 py-5 text-ink sm:px-8 sm:py-8 lg:px-12">
      <div className="mx-auto max-w-5xl">
        <header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9">
          <div className="flex flex-wrap items-start justify-between gap-5">
            <div className="flex gap-4">
              <div className="grid size-12 shrink-0 place-items-center rounded-2xl bg-harbor text-sea-glass shadow-[0_10px_22px_rgba(17,43,50,0.14)]"><Building2 aria-hidden="true" className="size-6" /></div>
              <div>
                <p className="text-[11px] font-bold tracking-[0.08em] text-tide">دليل العقارات</p>
                <h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">العقارات</h1>
                <p className="mt-3 max-w-2xl text-sm leading-7 text-muted">دليل تشغيلي لعقارات مؤسستك. يعرض بيانات التعريف والحالة فقط، دون حجوزات أو مبالغ مالية.</p>
              </div>
            </div>
            <div className="flex items-center gap-2 rounded-xl border border-[#d4dfda] bg-white/70 px-3 py-2 text-[11px] font-semibold text-tide"><ShieldCheck aria-hidden="true" className="size-4" />قراءة معزولة بالمؤسسة</div>
          </div>
          <div className="mt-7 flex items-end gap-3 border-t border-[#d4dfda] pt-5">
            <strong className="font-mono text-4xl font-medium tracking-[-0.09em] text-harbor">{properties.length}</strong>
            <span className="pb-1 text-xs text-muted">عقار مسجل</span>
          </div>
        </header>

        {properties.length === 0 ? (
          <section className="mt-6 rounded-[1.75rem] border border-dashed border-[#bfd1cb] bg-surface px-6 py-14 text-center sm:px-10">
            <div className="mx-auto grid size-12 place-items-center rounded-2xl bg-[#edf8f4] text-tide"><Building2 aria-hidden="true" className="size-5" /></div>
            <h2 className="mt-5 text-xl font-bold tracking-[-0.07em] text-harbor">لا توجد عقارات مسجلة بعد</h2>
            <p className="mx-auto mt-2 max-w-md text-sm leading-7 text-muted">تظهر هنا العقارات التي أضيفت عبر الإجراء المعتمد، مع رمزها التشغيلي وحالتها.</p>
          </section>
        ) : (
          <section aria-label="دليل العقارات" className="mt-6 grid gap-3 sm:grid-cols-2">
            {properties.map((property) => {
              const state = statusCopy[property.status];
              const StatusIcon = state.Icon;

              return (
                <article className="relative overflow-hidden rounded-[1.5rem] border border-line bg-surface p-5 shadow-[0_10px_28px_rgba(16,33,38,0.035)]" key={property.id}>
                  <span className={`absolute right-0 top-0 h-full w-1.5 ${property.status === "active" ? "bg-tide" : "bg-[#abb8b3]"}`} />
                  <div className="flex items-start justify-between gap-4">
                    <div className="min-w-0">
                      <p className="font-mono text-[10px] font-semibold tracking-[0.08em] text-tide" dir="ltr">{property.code}</p>
                      <h2 className="mt-2 truncate text-lg font-bold tracking-[-0.06em] text-harbor">{property.name}</h2>
                    </div>
                    <span className={`inline-flex shrink-0 items-center gap-1.5 rounded-full px-2.5 py-1 text-[10px] font-bold ${state.tone}`}><StatusIcon aria-hidden="true" className="size-3.5" />{state.label}</span>
                  </div>
                  <div className="mt-6 grid gap-2 border-t border-line pt-3 text-[11px] text-muted sm:grid-cols-2">
                    <span className="inline-flex items-center gap-1.5"><MapPinned aria-hidden="true" className="size-3.5 text-tide" /><bdi className="font-mono text-[10px] text-ink">{property.timezone}</bdi></span>
                    <time className="text-start font-mono text-[10px] text-ink sm:text-end" dateTime={property.createdAt}>{formatCreatedAt(property.createdAt)}</time>
                  </div>
                </article>
              );
            })}
          </section>
        )}
      </div>
    </main>
  );
}
