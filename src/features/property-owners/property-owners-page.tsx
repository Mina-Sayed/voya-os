import { Archive, Building2, CircleCheck, Clock3, ShieldCheck } from "lucide-react";
import { PropertyOwnerArchiveForm } from "./property-owner-archive-form";
import type { PropertyOwnerMutationAction } from "./property-owner-command-state";
import { PropertyOwnerCreateForm, type PropertyOwnerCreateAction } from "./property-owner-create-form";
import { PropertyOwnerEditForm } from "./property-owner-edit-form";
import { PropertyOwnerRestoreForm } from "./property-owner-restore-form";

export type PropertyOwnerListItem = Readonly<{
  id: string;
  displayName: string;
  phone: string | null;
  whatsapp: string | null;
  email: string | null;
  preferredContactMethod: string | null;
  notes: string | null;
  status: "active" | "inactive" | "archived";
  version: number;
  createdAt: string;
  archivedAt: string | null;
}>;

type PropertyOwnersPageProps = Readonly<{
  owners: readonly PropertyOwnerListItem[];
  createOwner?: PropertyOwnerCreateAction;
  updateOwner?: PropertyOwnerMutationAction;
  archiveOwner?: PropertyOwnerMutationAction;
  restoreOwner?: PropertyOwnerMutationAction;
  canManage?: boolean;
}>;

const statusCopy = {
  active: { label: "نشط", tone: "bg-[#edf8f4] text-tide", Icon: CircleCheck },
  inactive: { label: "غير نشط", tone: "bg-[#f1f0ed] text-muted", Icon: Clock3 },
  archived: { label: "مؤرشف", tone: "bg-[#fff1ed] text-[#9f493c]", Icon: Archive },
} as const;

function formatCreatedAt(createdAt: string) {
  return new Intl.DateTimeFormat("ar-EG", { day: "numeric", month: "short", year: "numeric" }).format(new Date(createdAt));
}

export function PropertyOwnersPage({ owners, createOwner, updateOwner, archiveOwner, restoreOwner, canManage = false }: PropertyOwnersPageProps) {
  return (
    <main className="min-h-screen bg-canvas px-4 py-5 text-ink sm:px-8 sm:py-8 lg:px-12">
      <div className="mx-auto max-w-5xl">
        <header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9">
          <div className="flex flex-wrap items-start justify-between gap-5">
            <div className="flex gap-4">
              <div className="grid size-12 shrink-0 place-items-center rounded-2xl bg-harbor text-sea-glass shadow-[0_10px_22px_rgba(17,43,50,0.14)]"><Building2 aria-hidden="true" className="size-6" /></div>
              <div>
                <p className="text-[11px] font-bold tracking-[0.08em] text-tide">سجل التشغيل</p>
                <h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">ملاك العقارات</h1>
                <p className="mt-3 max-w-2xl text-sm leading-7 text-muted">سجل موحد للجهات المالكة المرتبطة بعقارات مؤسستك. لا تظهر هنا أي بيانات مالية أو تسويات.</p>
              </div>
            </div>
            <div className="flex items-center gap-2 rounded-xl border border-[#d4dfda] bg-white/70 px-3 py-2 text-[11px] font-semibold text-tide"><ShieldCheck aria-hidden="true" className="size-4" />قراءة محمية حسب العضوية</div>
          </div>
          <div className="mt-7 flex items-end gap-3 border-t border-[#d4dfda] pt-5">
            <strong className="font-mono text-4xl font-medium tracking-[-0.09em] text-harbor">{owners.length}</strong>
            <span className="pb-1 text-xs text-muted">مالك مسجل</span>
          </div>
        </header>

        {createOwner ? <div className="mt-6"><PropertyOwnerCreateForm createOwner={createOwner} /></div> : null}

        {owners.length === 0 ? (
          <section className="mt-6 rounded-[1.75rem] border border-dashed border-[#bfd1cb] bg-surface px-6 py-14 text-center sm:px-10">
            <div className="mx-auto grid size-12 place-items-center rounded-2xl bg-[#edf8f4] text-tide"><Building2 aria-hidden="true" className="size-5" /></div>
            <h2 className="mt-5 text-xl font-bold tracking-[-0.07em] text-harbor">لا يوجد ملاك مسجلون بعد</h2>
            <p className="mx-auto mt-2 max-w-md text-sm leading-7 text-muted">عند إضافة مالك عبر الإجراء المعتمد سيظهر هنا مع حالته وسجل إنشائه.</p>
          </section>
        ) : (
          <section aria-label="سجل ملاك العقارات" className="mt-6 grid gap-3 sm:grid-cols-2">
            {owners.map((owner) => {
              const state = statusCopy[owner.status];
              const StatusIcon = state.Icon;

              return (
                <article className="relative overflow-hidden rounded-[1.5rem] border border-line bg-surface p-5 shadow-[0_10px_28px_rgba(16,33,38,0.035)]" key={owner.id}>
                  <span className={`absolute right-0 top-0 h-full w-1.5 ${owner.status === "active" ? "bg-tide" : owner.status === "archived" ? "bg-[#b66b5d]" : "bg-[#abb8b3]"}`} />
                  <div className="flex items-start justify-between gap-4">
                    <div className="min-w-0">
                      <p className="text-[10px] font-semibold tracking-[0.08em] text-muted">جهة مالكة</p>
                      <h2 className="mt-2 truncate text-lg font-bold tracking-[-0.06em] text-harbor">{owner.displayName}</h2>
                    </div>
                    <span className={`inline-flex shrink-0 items-center gap-1.5 rounded-full px-2.5 py-1 text-[10px] font-bold ${state.tone}`}><StatusIcon aria-hidden="true" className="size-3.5" />{state.label}</span>
                  </div>
                  <div className="mt-5 grid gap-2 border-t border-line pt-3 text-xs text-muted sm:grid-cols-2">
                    <span>{owner.phone ? `هاتف: ${owner.phone}` : "لا يوجد هاتف"}</span>
                    <span>{owner.whatsapp ? `واتساب: ${owner.whatsapp}` : "لا يوجد واتساب"}</span>
                    <span dir="ltr" className="text-start">{owner.email ?? "لا يوجد بريد إلكتروني"}</span>
                    <span>{owner.preferredContactMethod && owner.preferredContactMethod !== "none" ? `المفضلة: ${owner.preferredContactMethod}` : "وسيلة الاتصال غير محددة"}</span>
                  </div>
                  {owner.notes ? <p className="mt-3 rounded-lg bg-canvas px-3 py-2 text-xs leading-6 text-muted">{owner.notes}</p> : null}
                  <div className="mt-4 flex items-center justify-between border-t border-line pt-3 text-[11px] text-muted"><span>تاريخ الإضافة · الإصدار {owner.version}</span><time className="font-mono text-[10px] text-ink" dateTime={owner.createdAt}>{formatCreatedAt(owner.createdAt)}</time></div>
                  {canManage && owner.status !== "archived" && updateOwner ? <details className="mt-4 rounded-xl border border-line bg-canvas px-3 py-2"><summary className="cursor-pointer text-xs font-bold text-harbor">تعديل بيانات المالك</summary><PropertyOwnerEditForm owner={owner} updateOwner={updateOwner} /></details> : null}
                  {canManage && owner.status !== "archived" && archiveOwner ? <details className="mt-3 rounded-xl border border-[#ecd5cf] bg-[#fffaf8] px-3 py-2"><summary className="cursor-pointer text-xs font-bold text-[#9f493c]">أرشفة المالك</summary><PropertyOwnerArchiveForm archiveOwner={archiveOwner} ownerId={owner.id} version={owner.version} /></details> : null}
                  {canManage && owner.status === "archived" && restoreOwner ? <details className="mt-3 rounded-xl border border-[#d4dfda] bg-[#f8fbf9] px-3 py-2"><summary className="cursor-pointer text-xs font-bold text-tide">استعادة المالك</summary><PropertyOwnerRestoreForm ownerId={owner.id} restoreOwner={restoreOwner} version={owner.version} /></details> : null}
                </article>
              );
            })}
          </section>
        )}
      </div>
    </main>
  );
}
