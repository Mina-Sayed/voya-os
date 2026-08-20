"use client";

import { CircleAlert, LoaderCircle, Plus } from "lucide-react";
import { useActionState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";
import type { CrmCommandAction, CrmCommandState } from "@/features/crm/crm-command-state";

export type ClientCreateState = CrmCommandState;
export type ClientCreateAction = CrmCommandAction;

const initialState: ClientCreateState = { status: "idle", message: "" };
const inputClass = "mt-2 h-11 w-full rounded-xl border border-[#c9d9d3] bg-white px-3 text-sm text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas";
const labelClass = "text-xs font-bold text-harbor";

export function ClientCreateForm({ createClient }: Readonly<{ createClient: ClientCreateAction }>) {
  const [state, action, pending] = useActionState(createClient, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={action} className="rounded-[1.75rem] border border-[#d4dfda] bg-[#f0f7f4] p-5 shadow-[0_12px_30px_rgba(16,33,38,0.04)] sm:p-6" ref={formRef}>
    <input name="idempotency_key" type="hidden" value={idempotencyKey} />
    <div className="flex gap-3"><div className="grid size-10 shrink-0 place-items-center rounded-xl bg-harbor text-sea-glass"><Plus aria-hidden="true" className="size-5" /></div><div><h2 className="text-xl font-bold text-harbor">عميل CRM جديد</h2><p className="mt-1 text-xs leading-6 text-muted">احفظ بيانات الاتصال التي قدمها العميل فقط؛ لا تُخترع جنسية أو تفضيل لغة.</p></div></div>
    <div className="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3"><label className={labelClass}>اسم العميل<input autoComplete="name" className={inputClass} disabled={pending} maxLength={160} name="display_name" required /></label><label className={labelClass}>الهاتف<input className={inputClass} dir="ltr" disabled={pending} name="phone" /></label><label className={labelClass}>واتساب<input className={inputClass} dir="ltr" disabled={pending} name="whatsapp" /></label><label className={labelClass}>البريد<input className={inputClass} dir="ltr" disabled={pending} name="email" type="email" /></label><label className={labelClass}>الجنسية <span className="font-normal text-muted">(اختياري)</span><input className={inputClass} disabled={pending} name="nationality" /></label><label className={labelClass}>اللغة المفضلة <span className="font-normal text-muted">(اختياري)</span><select className={inputClass} defaultValue="" disabled={pending} name="preferred_language"><option value="">غير محددة</option><option value="ar">العربية</option><option value="en">English</option></select></label></div>
    <label className={`${labelClass} mt-4 block`}>ملاحظات<textarea className={`${inputClass} min-h-20 py-3`} disabled={pending} maxLength={4000} name="notes" /></label>
    <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-[#d4dfda] pt-4"><p className="text-[11px] text-muted">تحذير التكرار للمراجعة فقط، ولا يوجد دمج تلقائي.</p><button className="flex h-11 items-center gap-2 rounded-xl bg-harbor px-5 text-sm font-bold text-white hover:bg-tide disabled:bg-[#78938c]" disabled={pending} type="submit">{pending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin" /> : <Plus aria-hidden="true" className="size-4" />}إضافة العميل</button></div>
    {state.status !== "idle" ? <p aria-live="polite" className={`mt-3 flex gap-2 text-xs ${state.status === "success" ? "text-tide" : "text-coral"}`}><CircleAlert aria-hidden="true" className="size-4" />{state.message}</p> : null}
  </form>;
}
