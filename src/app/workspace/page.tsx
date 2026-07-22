import { Building2, ShieldCheck } from "lucide-react";
import { redirect } from "next/navigation";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { WorkspaceNavigation } from "@/features/workspace/workspace-navigation";

async function loadWorkspaceMembership() {
  try {
    const client = await createServerSupabaseClient();
    const { data: userData } = await client.auth.getUser();
    if (!userData.user) return { state: "signed_out" as const };

    const { data: memberships } = await client
      .from("organization_memberships")
      .select("id, organization_id, role, status")
      .eq("user_id", userData.user.id)
      .limit(2);
    const membership = resolveActiveMembership((memberships ?? []).map((item) => ({
      id: item.id,
      organizationId: item.organization_id,
      role: item.role,
      status: item.status,
    })));
    return membership ? { state: "member" as const } : { state: "pending" as const };
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) return { state: "unconfigured" as const };
    throw error;
  }
}

export default async function WorkspacePage() {
  const access = await loadWorkspaceMembership();
  if (access.state === "unconfigured" || access.state === "signed_out") redirect("/sign-in");
  if (access.state === "pending") redirect("/access-pending");

  return (
    <main className="grid min-h-screen place-items-center bg-canvas p-5 text-ink">
      <section className="w-full max-w-xl rounded-[2rem] border border-line bg-surface p-7 shadow-[0_24px_70px_rgba(16,33,38,0.08)] sm:p-10">
        <div className="grid size-12 place-items-center rounded-2xl bg-sea-glass/45 text-tide"><Building2 aria-hidden="true" className="size-5" /></div>
        <p className="mt-6 text-xs font-bold text-tide">مساحة عمل محمية</p>
        <h1 className="mt-3 text-3xl font-bold tracking-[-0.09em] text-harbor">تم التحقق من عضويتك</h1>
        <p className="mt-4 text-sm leading-7 text-muted">سيظهر هنا محتوى مؤسستك بعد ربط نماذج القراءة الحية. لا تعرض هذه المساحة بيانات تجريبية ولا تنفذ أي إجراء تشغيلي.</p>
        <WorkspaceNavigation />
        <div className="mt-7 flex items-center gap-2 border-t border-line pt-5 text-xs text-muted"><ShieldCheck aria-hidden="true" className="size-4 text-tide" />تمت مطابقة الجلسة مع عضوية نشطة على الخادم.</div>
      </section>
    </main>
  );
}
