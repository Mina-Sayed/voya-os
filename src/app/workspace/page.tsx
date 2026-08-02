import { Building2, ChevronLeft, ShieldCheck } from "lucide-react";
import { redirect } from "next/navigation";
import { loadWorkspaceContext } from "@/features/auth/workspace-context";
import { loadLiveDashboardData } from "@/features/dashboard/live-dashboard-data";
import { OperationsDashboard } from "@/features/dashboard/operations-dashboard";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { selectOrganizationAction } from "./actions";

export default async function WorkspacePage() {
  const access = await loadWorkspaceContext();
  if (access.state === "signed_out") redirect("/sign-in");
  if (access.state === "pending") redirect("/access-pending");

  if (access.state === "selection_required") {
    return (
      <main className="grid min-h-screen place-items-center bg-[#f3efe6] p-5 text-[#172a28] sm:p-8">
        <section className="w-full max-w-2xl rounded-[2rem] border border-[#d9dfd8] bg-[#fbfaf7] p-6 shadow-[0_24px_80px_rgba(26,52,45,0.12)] sm:p-10">
          <div className="flex items-center justify-between gap-4">
            <div className="flex items-center gap-3"><span className="grid size-11 place-items-center rounded-2xl bg-[#153b34] text-[#d5e9df]"><Building2 aria-hidden="true" className="size-5" /></span><div><p className="text-lg font-extrabold tracking-[-0.08em] text-[#173d35]">فُويا</p><p className="text-[10px] tracking-[0.16em] text-[#769187]">VOYA OS</p></div></div>
            <span className="rounded-full border border-[#cfe3d9] bg-[#eef7f2] px-3 py-1.5 text-[10px] font-bold text-[#1a6958]">حساب متعدد المؤسسات</span>
          </div>
          <div className="mt-12 max-w-lg"><p className="text-xs font-bold text-[#a2742d]">اختيار مساحة العمل</p><h1 className="mt-3 text-3xl font-extrabold tracking-[-0.09em] text-[#173d35] sm:text-4xl">أين تريد أن تعمل اليوم؟</h1><p className="mt-4 text-sm leading-7 text-[#687b74]">اختر مؤسسة واحدة. سيظل الاختيار محميًا ويُعاد التحقق منه على الخادم في كل طلب.</p></div>
          <form action={selectOrganizationAction} className="mt-8 grid gap-3">
            {access.memberships.map((membership) => <button className="group flex min-h-16 items-center gap-4 rounded-2xl border border-[#d9dfd8] bg-white px-4 text-start transition hover:-translate-y-0.5 hover:border-[#b88a3a] hover:shadow-[0_8px_22px_rgba(26,52,45,0.08)]" key={membership.id} name="organization_id" type="submit" value={membership.organizationId}><span className="grid size-10 place-items-center rounded-xl bg-[#eef7f2] text-[#1a6958]"><Building2 aria-hidden="true" className="size-5" /></span><span className="min-w-0 flex-1"><span className="block truncate text-sm font-extrabold text-[#173d35]">{membership.organizationName}</span><span className="mt-1 block text-[11px] text-[#71817b]">{membership.role}</span></span><ChevronLeft aria-hidden="true" className="size-5 text-[#879790] transition group-hover:-translate-x-1 group-hover:text-[#b88a3a]" /></button>)}
          </form>
          <div className="mt-8 flex items-center gap-2 border-t border-[#e4e6df] pt-5 text-xs text-[#71817b]"><ShieldCheck aria-hidden="true" className="size-4 text-[#1a6958]" />لا نعرض أي مؤسسة خارج عضويات حسابك النشطة.</div>
        </section>
      </main>
    );
  }

  const dashboard = await loadLiveDashboardData(access.membership);
  return <WorkspaceShell activeHref="/workspace" organizationName={access.membership.organizationName} role={access.membership.role}><OperationsDashboard data={dashboard} /></WorkspaceShell>;
}
