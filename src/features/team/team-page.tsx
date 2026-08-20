"use client";

import { CircleAlert, CircleCheck, Clock3, LoaderCircle, MailPlus, ShieldCheck, UserRound, UsersRound } from "lucide-react";
import { useActionState } from "react";

export type TeamActionState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
}>;

export type TeamAction = (
  previousState: TeamActionState,
  formData: FormData,
) => Promise<TeamActionState>;

export type TeamMemberListItem = Readonly<{
  id: string;
  displayName: string;
  role: "owner" | "manager" | "operator" | "viewer";
  status: "active" | "suspended";
  createdAt: string;
}>;

export type TeamInvitationListItem = Readonly<{
  id: string;
  email: string;
  role: "owner" | "manager" | "operator" | "viewer";
  status: "pending" | "accepted" | "revoked" | "expired";
  expiresAt: string;
  createdAt: string;
  acceptedAt: string | null;
  deliveryStatus: "pending" | "sent" | "failed";
}>;

type TeamPageProps = Readonly<{
  members: readonly TeamMemberListItem[];
  invitations: readonly TeamInvitationListItem[];
  canManage: boolean;
  invite: TeamAction;
  command: TeamAction;
}>;

const initialState: TeamActionState = { status: "idle", message: "" };

const roleCopy: Record<TeamMemberListItem["role"], string> = {
  owner: "مالك المؤسسة",
  manager: "مدير",
  operator: "مشغل",
  viewer: "مشاهد",
};

const invitationStatusCopy: Record<TeamInvitationListItem["status"], string> = {
  pending: "معلقة",
  accepted: "مقبولة",
  revoked: "ملغاة",
  expired: "منتهية",
};

function formatDate(value: string) {
  return new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium" }).format(new Date(value));
}

function Feedback({ state }: Readonly<{ state: TeamActionState }>) {
  if (state.status === "idle") return null;
  return <p aria-live="polite" className={`mt-3 flex items-start gap-2 text-xs leading-6 ${state.status === "success" ? "text-tide" : "text-coral"}`}>
    {state.status === "success" ? <CircleCheck aria-hidden="true" className="mt-1 size-3.5 shrink-0" /> : <CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0" />}
    {state.message}
  </p>;
}

function InviteForm({ action }: Readonly<{ action: TeamAction }>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return <form action={formAction} className="mt-6 rounded-[1.5rem] border border-[#d4dfda] bg-[#f0f7f4] p-5 sm:p-6">
    <div className="flex items-start gap-3">
      <div className="grid size-10 shrink-0 place-items-center rounded-xl bg-harbor text-sea-glass"><MailPlus aria-hidden="true" className="size-5" /></div>
      <div><h2 className="text-lg font-bold tracking-[-0.06em] text-harbor">دعوة عضو جديد</h2><p className="mt-1 text-xs leading-6 text-muted">الدعوة صالحة 72 ساعة. لا يظهر التوكن في المتصفح أو في سجل الفريق.</p></div>
    </div>
    <div className="mt-5 grid gap-4 sm:grid-cols-[1fr_180px_auto] sm:items-end">
      <label className="text-xs font-bold text-harbor" htmlFor="team-invite-email">البريد الإلكتروني<input autoComplete="email" className="ltr mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 text-left text-sm font-normal text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" disabled={pending} id="team-invite-email" name="email" placeholder="member@company.com" required type="email" /></label>
      <label className="text-xs font-bold text-harbor" htmlFor="team-invite-role">الدور<select className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-3 text-sm font-normal text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" defaultValue="operator" disabled={pending} id="team-invite-role" name="role"><option value="manager">مدير</option><option value="operator">مشغل</option><option value="viewer">مشاهد</option><option value="owner">مالك مؤسسة</option></select></label>
      <button className="flex h-12 items-center justify-center gap-2 rounded-xl bg-harbor px-5 text-sm font-bold text-white transition hover:bg-tide disabled:cursor-not-allowed disabled:bg-[#78938c]" disabled={pending} type="submit">{pending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <MailPlus aria-hidden="true" className="size-4" />}إرسال الدعوة</button>
    </div>
    <Feedback state={state} />
  </form>;
}

function CommandForm({ action, children, fields }: Readonly<{ action: TeamAction; children: React.ReactNode; fields: Readonly<Record<string, string>> }>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return <form action={formAction} className="inline-flex flex-wrap items-center gap-2">
    {Object.entries(fields).map(([name, value]) => <input key={name} name={name} type="hidden" value={value} />)}
    <button className="inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-[#bfd1cb] bg-white px-2.5 text-[10px] font-bold text-tide transition hover:border-tide hover:bg-[#edf8f4] disabled:cursor-not-allowed disabled:opacity-50" disabled={pending} type="submit">{pending ? <LoaderCircle aria-hidden="true" className="size-3 animate-spin" /> : null}{children}</button>
    <Feedback state={state} />
  </form>;
}

function RoleChangeForm({ action, member }: Readonly<{ action: TeamAction; member: TeamMemberListItem }>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return <form action={formAction} className="flex items-center gap-2">
    <input name="command" type="hidden" value="change_role" />
    <input name="membership_id" type="hidden" value={member.id} />
    <label className="sr-only" htmlFor={`role-${member.id}`}>دور {member.displayName}</label>
    <select className="h-9 rounded-lg border border-[#bfd1cb] bg-white px-2 text-[10px] font-bold text-tide outline-none focus:border-tide disabled:opacity-50" defaultValue={member.role} disabled={pending} id={`role-${member.id}`} name="role">
      <option value="manager">مدير</option><option value="operator">مشغل</option><option value="viewer">مشاهد</option>
    </select>
    <button className="h-9 rounded-lg border border-[#bfd1cb] bg-white px-2.5 text-[10px] font-bold text-tide hover:bg-[#edf8f4] disabled:opacity-50" disabled={pending} type="submit">{pending ? <LoaderCircle aria-hidden="true" className="inline size-3 animate-spin" /> : "حفظ الدور"}</button>
    <Feedback state={state} />
  </form>;
}

function MemberCard({ member, canManage, command }: Readonly<{ member: TeamMemberListItem; canManage: boolean; command: TeamAction }>) {
  const active = member.status === "active";
  return <article className="relative overflow-hidden rounded-[1.4rem] border border-line bg-surface p-4 shadow-[0_8px_22px_rgba(16,33,38,0.03)]">
    <span className={`absolute right-0 top-0 h-full w-1.5 ${active ? "bg-tide" : "bg-[#abb8b3]"}`} />
    <div className="flex items-start gap-3">
      <div className="grid size-10 shrink-0 place-items-center rounded-xl bg-[#edf8f4] text-tide"><UserRound aria-hidden="true" className="size-5" /></div>
      <div className="min-w-0 flex-1"><h3 className="truncate text-sm font-bold text-harbor">{member.displayName}</h3><p className="mt-1 text-xs text-muted">{roleCopy[member.role]}</p></div>
      <span className={`inline-flex shrink-0 items-center gap-1 rounded-full px-2 py-1 text-[10px] font-bold ${active ? "bg-[#edf8f4] text-tide" : "bg-[#f1f0ed] text-muted"}`}>{active ? <CircleCheck aria-hidden="true" className="size-3" /> : <Clock3 aria-hidden="true" className="size-3" />}{active ? "نشط" : "معلق"}</span>
    </div>
    <div className="mt-4 border-t border-line pt-3 text-[10px] text-muted"><span>منذ </span><time dateTime={member.createdAt}>{formatDate(member.createdAt)}</time></div>
    {canManage && member.role !== "owner" ? <div className="mt-3 flex flex-wrap gap-2 border-t border-line pt-3">
      <RoleChangeForm action={command} member={member} />
      {active ? <CommandForm action={command} fields={{ command: "suspend", membership_id: member.id, reason: "تعليق إداري" }}>تعليق</CommandForm> : <CommandForm action={command} fields={{ command: "reactivate", membership_id: member.id }}>إعادة تفعيل</CommandForm>}
      {active ? <CommandForm action={command} fields={{ command: "remove", membership_id: member.id, reason: "إزالة من الفريق" }}>إزالة</CommandForm> : null}
    </div> : null}
  </article>;
}

export function TeamPage({ members, invitations, canManage, invite, command }: TeamPageProps) {
  return <main className="min-h-screen bg-canvas px-4 py-5 text-ink sm:px-8 sm:py-8 lg:px-12"><div className="mx-auto max-w-6xl">
    <header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9"><div className="flex flex-wrap items-start justify-between gap-5"><div className="flex gap-4"><div className="grid size-12 shrink-0 place-items-center rounded-2xl bg-harbor text-sea-glass"><UsersRound aria-hidden="true" className="size-6" /></div><div><p className="text-[11px] font-bold tracking-[0.08em] text-tide">حوكمة مساحة العمل</p><h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">الفريق</h1><p className="mt-3 max-w-2xl text-sm leading-7 text-muted">أدر أعضاء المؤسسة ودعواتهم من خلال أوامر محمية. يظل التوكن الخام داخل حد الإرسال الخاص ولا يُعرض في الواجهة.</p></div></div><div className="flex items-center gap-2 rounded-xl border border-[#d4dfda] bg-white/70 px-3 py-2 text-[11px] font-semibold text-tide"><ShieldCheck aria-hidden="true" className="size-4" />عزل حسب المؤسسة</div></div><div className="mt-7 flex items-end gap-3 border-t border-[#d4dfda] pt-5"><strong className="font-mono text-4xl font-medium tracking-[-0.09em] text-harbor">{members.length}</strong><span className="pb-1 text-xs text-muted">عضو نشط أو معلّق</span><span className="mr-auto pb-1 text-xs text-muted">{invitations.filter((item) => item.status === "pending").length} دعوة معلقة</span></div></header>
    {canManage ? <InviteForm action={invite} /> : <p className="mt-6 rounded-2xl border border-line bg-surface px-5 py-4 text-xs leading-6 text-muted">يمكنك مراجعة الفريق والدعوات فقط؛ إجراءات الإدارة متاحة لمالك المؤسسة.</p>}
    <section aria-labelledby="team-members-heading" className="mt-7"><div className="flex items-center justify-between gap-3"><h2 className="text-xl font-bold tracking-[-0.07em] text-harbor" id="team-members-heading">أعضاء المؤسسة</h2><span className="text-xs text-muted">{members.length} سجل</span></div>{members.length === 0 ? <div className="mt-3 rounded-2xl border border-dashed border-[#bfd1cb] bg-surface px-5 py-10 text-center text-sm text-muted">لا يوجد أعضاء ظاهرون بعد.</div> : <div className="mt-3 grid gap-3 md:grid-cols-2">{members.map((member) => <MemberCard canManage={canManage} command={command} key={member.id} member={member} />)}</div>}</section>
    <section aria-labelledby="team-invitations-heading" className="mt-8"><div className="flex items-center justify-between gap-3"><h2 className="text-xl font-bold tracking-[-0.07em] text-harbor" id="team-invitations-heading">الدعوات</h2><span className="text-xs text-muted">{invitations.length} سجل</span></div>{invitations.length === 0 ? <div className="mt-3 rounded-2xl border border-dashed border-[#bfd1cb] bg-surface px-5 py-10 text-center text-sm text-muted">لا توجد دعوات مسجلة.</div> : <div className="mt-3 space-y-3">{invitations.map((invitation) => <article className="rounded-[1.25rem] border border-line bg-surface p-4" key={invitation.id}><div className="flex flex-wrap items-center gap-3"><MailPlus aria-hidden="true" className="size-4 text-tide" /><div className="min-w-0 flex-1"><p className="truncate text-sm font-bold text-harbor" dir="ltr">{invitation.email}</p><p className="mt-1 text-[11px] text-muted">{roleCopy[invitation.role]} · {invitationStatusCopy[invitation.status]}</p></div><time className="font-mono text-[10px] text-muted" dateTime={invitation.expiresAt}>حتى {formatDate(invitation.expiresAt)}</time></div>{canManage && invitation.status === "pending" ? <div className="mt-3 flex flex-wrap gap-2 border-t border-line pt-3"><CommandForm action={command} fields={{ command: "resend_invitation", invitation_id: invitation.id }}>إعادة إرسال</CommandForm><CommandForm action={command} fields={{ command: "revoke_invitation", invitation_id: invitation.id }}>إلغاء الدعوة</CommandForm></div> : null}</article>)}</div>}</section>
  </div></main>;
}
