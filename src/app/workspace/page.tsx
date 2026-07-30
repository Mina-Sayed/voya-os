import { Building2, ShieldCheck } from "lucide-react";
import { redirect } from "next/navigation";
import { loadWorkspaceContext } from "@/features/auth/workspace-context";
import { WorkspaceNavigation } from "@/features/workspace/workspace-navigation";
import { selectOrganizationAction } from "./actions";

export default async function WorkspacePage() {
  const access = await loadWorkspaceContext();
  if (access.state === "signed_out") redirect("/sign-in");
  if (access.state === "pending") redirect("/access-pending");

  if (access.state === "selection_required") {
    return (
      <main className="grid min-h-screen place-items-center bg-canvas p-5 text-ink">
        <section className="w-full max-w-xl rounded-[2rem] border border-line bg-surface p-7 shadow-[0_24px_70px_rgba(16,33,38,0.08)] sm:p-10">
          <div className="grid size-12 place-items-center rounded-2xl bg-sea-glass/45 text-tide"><Building2 aria-hidden="true" className="size-5" /></div>
          <p className="mt-6 text-xs font-bold text-tide">اختيار المؤسسة</p>
          <h1 className="mt-3 text-3xl font-bold tracking-[-0.09em] text-harbor">اختر مساحة العمل</h1>
          <p className="mt-4 text-sm leading-7 text-muted">لديك أكثر من عضوية نشطة. اختر المؤسسة التي تريد العمل داخلها الآن.</p>
          <form action={selectOrganizationAction} className="mt-6 grid gap-3">
            {access.memberships.map((membership) => (
              <button className="flex items-center justify-between rounded-xl border border-line bg-white px-4 py-3 text-start text-sm font-bold text-harbor hover:border-tide" key={membership.id} name="organization_id" type="submit" value={membership.organizationId}>
                <span>{membership.organizationName}</span><span className="text-xs font-normal text-muted">{membership.role}</span>
              </button>
            ))}
          </form>
        </section>
      </main>
    );
  }

  return (
    <main className="grid min-h-screen place-items-center bg-canvas p-5 text-ink">
      <section className="w-full max-w-xl rounded-[2rem] border border-line bg-surface p-7 shadow-[0_24px_70px_rgba(16,33,38,0.08)] sm:p-10">
        <div className="grid size-12 place-items-center rounded-2xl bg-sea-glass/45 text-tide"><Building2 aria-hidden="true" className="size-5" /></div>
        <p className="mt-6 text-xs font-bold text-tide">مساحة عمل محمية</p>
        <h1 className="mt-3 text-3xl font-bold tracking-[-0.09em] text-harbor">{access.membership.organizationName}</h1>
        <p className="mt-4 text-sm leading-7 text-muted">سيظهر هنا محتوى مؤسستك بعد ربط نماذج القراءة الحية. لا تعرض هذه المساحة بيانات تجريبية ولا تنفذ أي إجراء تشغيلي.</p>
        <WorkspaceNavigation />
        <div className="mt-7 flex items-center gap-2 border-t border-line pt-5 text-xs text-muted"><ShieldCheck aria-hidden="true" className="size-4 text-tide" />تمت مطابقة الجلسة مع عضوية نشطة على الخادم.</div>
      </section>
    </main>
  );
}
