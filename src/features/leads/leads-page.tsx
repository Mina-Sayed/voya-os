import { Archive, CircleAlert, CircleCheck, Clock3, History, RadioTower, ShieldCheck } from "lucide-react";
import { LeadCreateForm, type LeadCreateAction } from "./lead-create-form";
import { LeadActivityForm, LeadArchiveForm, LeadConvertForm, LeadDetailsSummary, LeadEditForm, LeadFollowUpCompleteForm, LeadFollowUpForm } from "./lead-command-forms";
import type { CrmCommandAction } from "@/features/crm/crm-command-state";
import { leadDisplayName } from "./lead-types";
import type { LeadActivityItem, LeadFollowUpItem, LeadItem } from "./lead-types";

export type { LeadActivityItem, LeadFollowUpItem, LeadItem } from "./lead-types";

const sourceLabel: Record<string, string> = { website: "الموقع", referral: "إحالة", walk_in: "زيارة مباشرة", whatsapp: "واتساب", other: "مصدر آخر" };
const statusLabel: Record<string, string> = { new: "جديد", contacted: "تم التواصل", qualified: "مؤهل", offered: "عُرضت خيارات", won: "تحويل ناجح", lost: "مفقود" };
const statusTone: Record<string, string> = { new: "bg-[#fff8e9] text-[#85652e]", contacted: "bg-[#edf8f4] text-tide", qualified: "bg-[#edf8f4] text-tide", offered: "bg-[#edf3fb] text-[#48647e]", won: "bg-sea-glass text-tide", lost: "bg-[#f1f0ed] text-muted" };
const activityLabel: Record<string, string> = { call: "مكالمة", whatsapp: "واتساب", email: "بريد", note: "ملاحظة", status_change: "تغيير حالة", property_offered: "عرض عقار", booking_created: "إنشاء حجز" };

type LeadsPageProps = Readonly<{
  leads: readonly LeadItem[];
  timeZone: string;
  createLead?: LeadCreateAction;
  updateLead?: CrmCommandAction;
  archiveLead?: CrmCommandAction;
  createActivity?: CrmCommandAction;
  createFollowUp?: CrmCommandAction;
  completeFollowUp?: CrmCommandAction;
  convertLead?: CrmCommandAction;
}>;

function formatDateTime(value: string): string {
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? value : new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium", timeStyle: "short" }).format(parsed);
}

function ContactLine({ lead }: Readonly<{ lead: LeadItem }>) {
  const contacts = [lead.phone ? <bdi dir="ltr" key="phone">{lead.phone}</bdi> : null, lead.whatsapp ? <bdi dir="ltr" key="whatsapp">واتساب: {lead.whatsapp}</bdi> : null, lead.email ? <bdi dir="ltr" key="email">{lead.email}</bdi> : null].filter(Boolean);
  return contacts.length ? <div className="mt-3 flex flex-wrap gap-2 text-[11px] text-muted">{contacts.map((contact, index) => <span className="rounded-lg bg-canvas px-2 py-1" key={index}>{contact}</span>)}</div> : null;
}

function ActivityTimeline({ activities }: Readonly<{ activities: readonly LeadActivityItem[] }>) {
  if (activities.length === 0) return <p className="mt-3 text-[11px] text-muted">لا يوجد نشاط محفوظ بعد.</p>;
  return <ol className="mt-3 space-y-2">{activities.map((activity) => <li className="rounded-lg bg-canvas p-2.5" key={activity.id}><div className="flex flex-wrap justify-between gap-2 text-[10px] text-muted"><span className="font-bold text-tide">{activityLabel[activity.activityType] ?? activity.activityType}</span><time dateTime={activity.createdAt}>{formatDateTime(activity.createdAt)}</time></div><p className="mt-1 text-[11px] leading-5 text-ink">{activity.content}</p></li>)}</ol>;
}

function FollowUpQueue({ followUps, completeFollowUp }: Readonly<{ followUps: readonly LeadFollowUpItem[]; completeFollowUp?: CrmCommandAction }>) {
  if (followUps.length === 0) return <p className="mt-3 text-[11px] text-muted">لا توجد متابعات بعد.</p>;
  return <ul className="mt-3 space-y-2">{followUps.map((followUp) => <li className="rounded-lg bg-canvas p-2.5" key={followUp.id}><div className="flex flex-wrap items-center justify-between gap-2"><span className={`rounded-full px-2 py-1 text-[10px] font-bold ${followUp.status === "completed" ? "bg-sea-glass text-tide" : "bg-[#fff8e9] text-[#85652e]"}`}>{followUp.status === "completed" ? "مكتملة" : followUp.status === "cancelled" ? "ملغاة" : "معلقة"}</span><time className="text-[10px] text-muted" dateTime={followUp.dueAt}>{formatDateTime(followUp.dueAt)}</time></div><p className="mt-2 text-[11px] leading-5 text-ink">{followUp.note}</p>{followUp.status === "pending" && completeFollowUp ? <LeadFollowUpCompleteForm completeFollowUp={completeFollowUp} followUp={followUp} /> : null}</li>)}</ul>;
}

function LeadCard({ lead, timeZone, updateLead, archiveLead, createActivity, createFollowUp, completeFollowUp, convertLead }: Readonly<{ lead: LeadItem; timeZone: string; updateLead?: CrmCommandAction; archiveLead?: CrmCommandAction; createActivity?: CrmCommandAction; createFollowUp?: CrmCommandAction; completeFollowUp?: CrmCommandAction; convertLead?: CrmCommandAction }>) {
  const archived = Boolean(lead.archivedAt);
  const activities = lead.activities ?? [];
  const followUps = lead.followUps ?? [];
  return <article className={`relative overflow-hidden rounded-[1.5rem] border bg-surface p-5 shadow-[0_10px_28px_rgba(16,33,38,0.035)] ${archived ? "border-[#e3d8d2] opacity-75" : "border-line"}`}>
    <span className={`absolute right-0 top-0 h-full w-1.5 ${archived ? "bg-[#b7aaa3]" : "bg-tide"}`} />
    <div className="flex flex-wrap items-start justify-between gap-3"><div><p className="text-[10px] font-bold text-tide">{sourceLabel[lead.source] ?? lead.source}</p><h2 className="mt-2 text-lg font-bold tracking-[-0.05em] text-harbor">{leadDisplayName(lead)}</h2></div><span className={`inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-[10px] font-bold ${archived ? "bg-[#f1f0ed] text-muted" : statusTone[lead.status] ?? "bg-canvas text-muted"}`}>{archived ? <Archive aria-hidden="true" className="size-3" /> : lead.status === "won" ? <CircleCheck aria-hidden="true" className="size-3" /> : <Clock3 aria-hidden="true" className="size-3" />}{archived ? "مؤرشف" : statusLabel[lead.status] ?? lead.status}</span></div>
    <ContactLine lead={lead} />
    <div className="mt-4 grid gap-2 border-t border-line pt-3 text-[11px] text-muted sm:grid-cols-2"><span>المنطقة: <b className="text-ink">{lead.requestedArea ?? "غير محددة"}</b></span><span>الفترة: <b className="font-mono text-ink" dir="ltr">{lead.requestedCheckIn && lead.requestedCheckOut ? `${lead.requestedCheckIn} ← ${lead.requestedCheckOut}` : "غير محددة"}</b></span><span>الضيوف: <b className="text-ink">{lead.guests ?? "—"}</b></span><span>الميزانية: <b className="text-ink">{lead.budgetText ?? "غير مسجلة"}</b></span></div>
    {lead.duplicateWarning ? <p className="mt-3 flex items-start gap-1.5 rounded-lg border border-[#ead7a8] bg-[#fff8e9] p-2.5 text-[10px] leading-5 text-[#85652e]"><CircleAlert className="mt-0.5 size-3.5 shrink-0" />يوجد طلب آخر بوسيلة اتصال مشابهة. راجع السجل يدويًا قبل الدمج أو التحويل.</p> : null}
    <LeadDetailsSummary lead={lead} />
    <details className="mt-4 border-t border-line pt-3"><summary className="cursor-pointer text-[11px] font-bold text-tide">النشاط والمتابعات ({activities.length} / {followUps.length})</summary><div className="mt-3"><ActivityTimeline activities={activities} /><FollowUpQueue completeFollowUp={completeFollowUp} followUps={followUps} />{createActivity ? <LeadActivityForm createActivity={createActivity} leadId={lead.id} /> : null}{createFollowUp ? <LeadFollowUpForm createFollowUp={createFollowUp} leadId={lead.id} /> : null}</div></details>
    {!archived && updateLead ? <details className="mt-3 border-t border-line pt-3"><summary className="cursor-pointer inline-flex items-center gap-1.5 text-[11px] font-bold text-tide"><ClipboardEditIcon />تعديل بيانات الطلب</summary><LeadEditForm lead={lead} timeZone={timeZone} updateLead={updateLead} /></details> : null}
    {!archived && convertLead && !lead.convertedClientId && lead.status !== "lost" ? <LeadConvertForm convertLead={convertLead} leadId={lead.id} /> : null}
    {!archived && archiveLead ? <details className="mt-3"><summary className="cursor-pointer text-[10px] font-bold text-[#9f493c]">أرشفة الطلب</summary><LeadArchiveForm archiveLead={archiveLead} lead={lead} /></details> : null}
  </article>;
}

function ClipboardEditIcon() {
  return <History aria-hidden="true" className="size-3.5" />;
}

export function LeadsPage({ leads, timeZone, createLead, updateLead, archiveLead, createActivity, createFollowUp, completeFollowUp, convertLead }: LeadsPageProps) {
  const active = leads.filter((lead) => !lead.archivedAt).length;
  const pendingFollowUps = leads.reduce((count, lead) => count + (lead.followUps?.filter((item) => item.status === "pending").length ?? 0), 0);
  return <main className="min-h-screen bg-canvas px-4 py-5 text-ink sm:px-8 sm:py-8 lg:px-12"><div className="mx-auto max-w-6xl"><header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9"><div className="flex flex-wrap justify-between gap-5"><div className="flex gap-4"><div className="grid size-12 place-items-center rounded-2xl bg-harbor text-sea-glass"><RadioTower aria-hidden="true" className="size-6" /></div><div><p className="text-[11px] font-bold tracking-[.08em] text-tide">CRM وتشغيل المبيعات</p><h1 className="mt-2 text-3xl font-bold tracking-[-.09em] text-harbor sm:text-4xl">العملاء المحتملون</h1><p className="mt-3 max-w-2xl text-sm leading-7 text-muted">سجل موحد للطلب والاتصال والنشاط والمتابعة. التحويل إلى عميل يحفظ الدليل ولا ينفذ أسعارًا أو حجزًا تلقائيًا.</p></div></div><span className="flex h-fit items-center gap-2 rounded-xl border border-[#d4dfda] bg-white/70 px-3 py-2 text-[11px] font-bold text-tide"><ShieldCheck aria-hidden="true" className="size-4" />مؤسسة معزولة</span></div><div className="mt-7 grid gap-3 border-t border-[#d4dfda] pt-5 sm:grid-cols-3"><div><strong className="font-mono text-3xl font-medium text-harbor">{active}</strong><p className="mt-1 text-xs text-muted">طلبات نشطة</p></div><div><strong className="font-mono text-3xl font-medium text-[#85652e]">{pendingFollowUps}</strong><p className="mt-1 text-xs text-muted">متابعات معلقة</p></div><div><strong className="font-mono text-3xl font-medium text-tide">{leads.length}</strong><p className="mt-1 text-xs text-muted">إجمالي السجل</p></div></div></header>{createLead ? <div className="mt-6"><LeadCreateForm createLead={createLead} /></div> : null}{leads.length === 0 ? <section className="mt-6 rounded-[1.75rem] border border-dashed border-[#bfd1cb] bg-surface px-6 py-14 text-center"><RadioTower aria-hidden="true" className="mx-auto size-6 text-tide" /><h2 className="mt-5 text-xl font-bold text-harbor">لا توجد طلبات مسجلة</h2><p className="mt-2 text-sm text-muted">أضف أول طلب بوسيلة اتصال واحدة على الأقل.</p></section> : <section aria-label="سجل العملاء المحتملين" className="mt-6 grid gap-4 lg:grid-cols-2">{leads.map((lead) => <LeadCard archiveLead={archiveLead} completeFollowUp={completeFollowUp} convertLead={convertLead} createActivity={createActivity} createFollowUp={createFollowUp} key={lead.id} lead={lead} timeZone={timeZone} updateLead={updateLead} />)}</section>}</div></main>;
}
