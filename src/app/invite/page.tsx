import { Clock3, Link2, ShieldCheck, UserPlus } from "lucide-react";
import Link from "next/link";
import type { ReactNode } from "react";
import { isValidInvitationToken } from "@/features/auth/invitation-token";
import { InvitationAcceptForm } from "@/features/organizations/invitation-accept-form";
import { loadActiveWorkspaceMemberships } from "@/features/auth/workspace-context";
import { acceptOrganizationInvitationAction } from "./actions";

type InvitePageProps = Readonly<{
  searchParams: Promise<{ token?: string | string[] }>;
}>;

function InviteShell({ children }: Readonly<{ children: ReactNode }>) {
  return <main className="grid min-h-screen place-items-center bg-canvas p-5 text-ink"><section className="w-full max-w-xl rounded-[2rem] border border-line bg-surface p-7 shadow-[0_24px_70px_rgba(16,33,38,0.08)] sm:p-10"><div className="mx-auto grid size-14 place-items-center rounded-2xl bg-sea-glass/45 text-tide"><UserPlus aria-hidden="true" className="size-7" /></div>{children}</section></main>;
}

export default async function InvitePage({ searchParams }: InvitePageProps) {
  const rawToken = (await searchParams).token;
  const token = (Array.isArray(rawToken) ? rawToken[0] : rawToken)?.trim().toLowerCase() ?? "";
  if (!isValidInvitationToken(token)) {
    return <InviteShell><p className="mt-6 text-center text-xs font-bold text-coral">رابط الدعوة غير صالح أو ناقص.</p><Link className="mt-6 block text-center text-xs font-bold text-tide" href="/sign-in">العودة إلى تسجيل الدخول</Link></InviteShell>;
  }

  const memberships = await loadActiveWorkspaceMemberships();
  if (memberships.state === "signed_out") {
    return <InviteShell><p className="mt-6 text-center text-xs font-bold text-tide">دعوة لمساحة عمل Voya OS</p><h1 className="mt-3 text-center text-3xl font-bold tracking-[-0.09em] text-harbor">سجّل الدخول لقبول الدعوة</h1><p className="mt-4 text-center text-sm leading-7 text-muted">استخدم البريد المرتبط بالدعوة. بعد تسجيل الدخول ستعود تلقائيًا إلى هذه الدعوة.</p><Link className="mt-7 flex h-13 items-center justify-center gap-2 rounded-2xl bg-harbor px-5 text-sm font-bold text-white transition hover:bg-tide" href={`/sign-in?token=${encodeURIComponent(token)}`}><Link2 aria-hidden="true" className="size-4" />الانتقال إلى تسجيل الدخول</Link><p className="mt-5 text-center text-xs leading-6 text-muted">إذا لم يكن لديك حساب، يمكنك إنشاء حساب بالبريد من نفس الصفحة.</p></InviteShell>;
  }

  return <InviteShell><p className="mt-6 text-center text-xs font-bold text-tide">دعوة لمساحة عمل Voya OS</p><h1 className="mt-3 text-center text-3xl font-bold tracking-[-0.09em] text-harbor">أنت مدعو للانضمام إلى فريق تشغيل</h1><p className="mt-4 text-center text-sm leading-7 text-muted">اقبل الدعوة لإضافة المؤسسة إلى حسابك. سيظل فتح بيانات التشغيل مشروطًا بالتحقق من MFA.</p><InvitationAcceptForm action={acceptOrganizationInvitationAction} token={token} /><div className="mt-6 flex items-start gap-2 border-t border-line pt-5 text-xs leading-6 text-muted"><ShieldCheck aria-hidden="true" className="mt-1 size-4 shrink-0 text-tide" />رابط الدعوة مؤقت. إذا انتهت صلاحيته، اطلب من مالك المؤسسة إرسال دعوة جديدة.</div><div className="mt-4 flex items-start gap-2 text-xs leading-6 text-muted"><Clock3 aria-hidden="true" className="mt-1 size-4 shrink-0 text-tide" />بعد القبول، سيطلب النظام MFA قبل فتح مساحة العمل.</div></InviteShell>;
}
