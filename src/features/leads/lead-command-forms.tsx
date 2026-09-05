"use client";

import { Archive, Check, CircleAlert, ClipboardEdit, History, LoaderCircle, MessageSquarePlus, RefreshCw, Send, UserRoundCheck } from "lucide-react";
import { useActionState } from "react";
import { formatLocalDateTime } from "@/domain/time/iso-datetime";
import type { CrmCommandAction, CrmCommandState } from "@/features/crm/crm-command-state";
import { useCommandForm } from "@/features/shared/use-command-form";
import { leadDisplayName } from "./lead-types";
import type { LeadFollowUpItem, LeadItem } from "./lead-types";

const initialState: CrmCommandState = { status: "idle", message: "" };
const inputClass = "mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas";
const labelClass = "text-[11px] font-bold text-harbor";

function Feedback({ state }: Readonly<{ state: CrmCommandState }>) {
  if (state.status === "idle" || !state.message) return null;
  return <p aria-live="polite" className={`mt-2 flex items-center gap-1.5 text-[11px] ${state.status === "success" ? "text-tide" : "text-coral"}`}><CircleAlert aria-hidden="true" className="size-3.5" />{state.message}</p>;
}

export function LeadEditForm({ lead, timeZone, updateLead }: Readonly<{ lead: LeadItem; timeZone: string; updateLead: CrmCommandAction }>) {
  const [state, action, pending] = useActionState(updateLead, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={action} className="mt-4 border-t border-line pt-4" ref={formRef}>
      <input name="lead_id" type="hidden" value={lead.id} /><input name="expected_version" type="hidden" value={lead.version ?? 1} /><input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="grid gap-3 sm:grid-cols-2">
        <label className={labelClass}>الاسم<input className={inputClass} defaultValue={leadDisplayName(lead)} disabled={pending} name="name" required /></label>
        <label className={labelClass}>الهاتف<input className={inputClass} defaultValue={lead.phone ?? ""} dir="ltr" disabled={pending} name="phone" /></label>
        <label className={labelClass}>واتساب<input className={inputClass} defaultValue={lead.whatsapp ?? ""} dir="ltr" disabled={pending} name="whatsapp" /></label>
        <label className={labelClass}>البريد<input className={inputClass} defaultValue={lead.email ?? ""} dir="ltr" disabled={pending} name="email" type="email" /></label>
        <label className={labelClass}>المصدر<select className={inputClass} defaultValue={lead.source} disabled={pending} name="source"><option value="website">الموقع</option><option value="referral">إحالة</option><option value="walk_in">زيارة مباشرة</option><option value="whatsapp">واتساب</option><option value="other">مصدر آخر</option></select></label>
        <label className={labelClass}>الحالة<select className={inputClass} defaultValue={lead.status} disabled={pending} name="status"><option value="new">جديد</option><option value="contacted">تم التواصل</option><option value="qualified">مؤهل</option><option value="offered">عُرضت خيارات</option><option value="won">فاز / عميل</option><option value="lost">مفقود</option></select></label>
        <label className={labelClass}>المنطقة<input className={inputClass} defaultValue={lead.requestedArea ?? ""} disabled={pending} name="requested_area" /></label>
        <label className={labelClass}>الوصول<input className={inputClass} defaultValue={lead.requestedCheckIn ?? ""} disabled={pending} name="requested_check_in" type="date" /></label>
        <label className={labelClass}>المغادرة<input className={inputClass} defaultValue={lead.requestedCheckOut ?? ""} disabled={pending} name="requested_check_out" type="date" /></label>
        <label className={labelClass}>الضيوف<input className={inputClass} defaultValue={lead.guests ?? ""} disabled={pending} min="1" name="guests" type="number" /></label>
        <label className={labelClass}>غرف النوم<input className={inputClass} defaultValue={lead.bedrooms ?? ""} disabled={pending} min="0" name="bedrooms" type="number" /></label>
        <label className={labelClass}>المتابعة التالية<input className={inputClass} defaultValue={formatLocalDateTime(lead.nextFollowUpAt, timeZone)} disabled={pending} name="next_follow_up_at" type="datetime-local" /></label>
      </div>
      <label className={`${labelClass} mt-3 block`}>الميزانية<textarea className={`${inputClass} min-h-12 py-2`} defaultValue={lead.budgetText ?? ""} disabled={pending} maxLength={200} name="budget_text" /></label>
      <label className={`${labelClass} mt-3 block`}>الملاحظات<textarea className={`${inputClass} min-h-16 py-2`} defaultValue={lead.notes ?? ""} disabled={pending} maxLength={4000} name="notes" /></label>
      <button className="mt-3 inline-flex h-9 items-center gap-1.5 rounded-lg bg-harbor px-3 text-[11px] font-bold text-white disabled:opacity-60" disabled={pending} type="submit">{pending ? <LoaderCircle className="size-3.5 animate-spin" /> : <ClipboardEdit className="size-3.5" />}حفظ التعديل</button>
      <Feedback state={state} />
    </form>
  );
}

export function LeadActivityForm({ leadId, createActivity }: Readonly<{ leadId: string; createActivity: CrmCommandAction }>) {
  const [state, action, pending] = useActionState(createActivity, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={action} className="mt-4 border-t border-line pt-4" ref={formRef}>
      <input name="lead_id" type="hidden" value={leadId} /><input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="grid gap-3 sm:grid-cols-[10rem_minmax(0,1fr)]">
        <label className={labelClass}>نوع النشاط<select className={inputClass} defaultValue="note" disabled={pending} name="activity_type"><option value="note">ملاحظة</option><option value="call">مكالمة</option><option value="whatsapp">واتساب</option><option value="email">بريد</option><option value="property_offered">عرض عقار</option><option value="booking_created">إنشاء حجز</option><option value="status_change">تغيير حالة</option></select></label>
        <label className={labelClass}>ما الذي حدث؟<textarea className={`${inputClass} min-h-10 py-2`} disabled={pending} maxLength={4000} name="content" placeholder="سجل دليلًا مختصرًا قابلًا للمراجعة" required /></label>
      </div>
      <button className="mt-3 inline-flex h-9 items-center gap-1.5 rounded-lg border border-[#bfd1cb] bg-white px-3 text-[11px] font-bold text-tide disabled:opacity-60" disabled={pending} type="submit">{pending ? <LoaderCircle className="size-3.5 animate-spin" /> : <MessageSquarePlus className="size-3.5" />}إضافة للسجل</button>
      <Feedback state={state} />
    </form>
  );
}

export function LeadFollowUpForm({ leadId, createFollowUp }: Readonly<{ leadId: string; createFollowUp: CrmCommandAction }>) {
  const [state, action, pending] = useActionState(createFollowUp, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={action} className="mt-4 border-t border-line pt-4" ref={formRef}>
      <input name="lead_id" type="hidden" value={leadId} /><input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="grid gap-3 sm:grid-cols-2">
        <label className={labelClass}>موعد المتابعة<input className={inputClass} disabled={pending} name="due_at" required type="datetime-local" /></label>
        <label className={labelClass}>المطلوب تنفيذه<textarea className={`${inputClass} min-h-10 py-2`} disabled={pending} maxLength={2000} name="note" required /></label>
      </div>
      <button className="mt-3 inline-flex h-9 items-center gap-1.5 rounded-lg border border-[#bfd1cb] bg-white px-3 text-[11px] font-bold text-tide disabled:opacity-60" disabled={pending} type="submit">{pending ? <LoaderCircle className="size-3.5 animate-spin" /> : <Send className="size-3.5" />}جدولة متابعة</button>
      <Feedback state={state} />
    </form>
  );
}

export function LeadFollowUpCompleteForm({ followUp, completeFollowUp }: Readonly<{ followUp: LeadFollowUpItem; completeFollowUp: CrmCommandAction }>) {
  const [state, action, pending] = useActionState(completeFollowUp, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={action} className="mt-2" ref={formRef}>
      <input name="follow_up_id" type="hidden" value={followUp.id} /><input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="flex flex-wrap items-end gap-2"><label className="min-w-48 flex-1 text-[10px] font-bold text-harbor">ملاحظة الإكمال<input className="mt-1 h-8 w-full rounded-lg border border-[#c9d9d3] bg-white px-2 text-[11px]" disabled={pending} name="completion_note" /></label><button className="inline-flex h-8 items-center gap-1 rounded-lg bg-tide px-2.5 text-[10px] font-bold text-white disabled:opacity-60" disabled={pending} type="submit">{pending ? <LoaderCircle className="size-3 animate-spin" /> : <Check className="size-3" />}إكمال</button></div>
      <Feedback state={state} />
    </form>
  );
}

export function LeadConvertForm({ leadId, convertLead }: Readonly<{ leadId: string; convertLead: CrmCommandAction }>) {
  const [state, action, pending] = useActionState(convertLead, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={action} className="mt-3" ref={formRef}><input name="lead_id" type="hidden" value={leadId} /><input name="idempotency_key" type="hidden" value={idempotencyKey} /><button className="inline-flex h-9 items-center gap-1.5 rounded-lg bg-harbor px-3 text-[11px] font-bold text-white disabled:opacity-60" disabled={pending} type="submit">{pending ? <LoaderCircle className="size-3.5 animate-spin" /> : <UserRoundCheck className="size-3.5" />}تحويل إلى عميل</button><p className="mt-1 text-[10px] text-muted">التحويل ذري ويحفظ النشاط ولا يدمج التكرارات تلقائيًا.</p><Feedback state={state} /></form>;
}

export function LeadArchiveForm({ lead, archiveLead }: Readonly<{ lead: LeadItem; archiveLead: CrmCommandAction }>) {
  const [state, action, pending] = useActionState(archiveLead, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={action} className="mt-4 border-t border-[#ead8d2] pt-4" ref={formRef}><input name="lead_id" type="hidden" value={lead.id} /><input name="expected_version" type="hidden" value={lead.version ?? 1} /><input name="idempotency_key" type="hidden" value={idempotencyKey} /><label className="text-[10px] font-bold text-harbor">سبب الأرشفة<input className="mt-1 h-9 w-full rounded-lg border border-[#e3c9c1] bg-white px-2 text-[11px]" disabled={pending} name="reason" required /></label><button className="mt-2 inline-flex h-8 items-center gap-1 rounded-lg border border-[#d9aaa0] px-2.5 text-[10px] font-bold text-[#9f493c] disabled:opacity-60" disabled={pending} type="submit">{pending ? <LoaderCircle className="size-3 animate-spin" /> : <Archive className="size-3" />}أرشفة الطلب</button><Feedback state={state} /></form>;
}

export function LeadDetailsSummary({ lead }: Readonly<{ lead: LeadItem }>) {
  return <div className="mt-4 grid gap-2 border-t border-line pt-4 text-[11px] text-muted sm:grid-cols-2"><span className="inline-flex items-center gap-1.5"><History className="size-3.5 text-tide" />{lead.activities?.length ?? 0} نشاط محفوظ</span><span className="inline-flex items-center gap-1.5"><RefreshCw className="size-3.5 text-tide" />{lead.followUps?.filter((item) => item.status === "pending").length ?? 0} متابعة معلقة</span></div>;
}
