"use client";

import { CircleAlert, LoaderCircle, Plus } from "lucide-react";
import { useActionState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";
import type { CrmCommandAction, CrmCommandState } from "@/features/crm/crm-command-state";

export type LeadCreateState = CrmCommandState;
export type LeadCreateAction = CrmCommandAction;

const initialState: LeadCreateState = { status: "idle", message: "" };

const inputClass = "mt-2 h-11 w-full rounded-xl border border-[#c9d9d3] bg-white px-3 text-sm text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas";
const labelClass = "text-xs font-bold text-harbor";

export function LeadCreateForm({ createLead }: Readonly<{ createLead: LeadCreateAction }>) {
  const [state, action, pending] = useActionState(createLead, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);

  return (
    <form action={action} className="rounded-[1.75rem] border border-[#d4dfda] bg-[#f0f7f4] p-5 shadow-[0_12px_30px_rgba(16,33,38,0.04)] sm:p-6" ref={formRef}>
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="flex gap-3">
        <div className="grid size-10 shrink-0 place-items-center rounded-xl bg-harbor text-sea-glass"><Plus aria-hidden="true" className="size-5" /></div>
        <div>
          <h2 className="text-xl font-bold text-harbor">طلب CRM جديد</h2>
          <p className="mt-1 text-xs leading-6 text-muted">سجّل الطلب ووسيلة اتصال واحدة على الأقل. السعر والحجز لا يتغيران من هذا النموذج.</p>
        </div>
      </div>

      <div className="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <label className={labelClass} htmlFor="lead-name">اسم / عنوان الطلب<input className={inputClass} disabled={pending} id="lead-name" maxLength={160} name="name" placeholder="مثال: أحمد — إقامة عائلية" required /></label>
        <label className={labelClass} htmlFor="lead-phone">الهاتف<input className={inputClass} dir="ltr" disabled={pending} id="lead-phone" name="phone" placeholder="+201..." /></label>
        <label className={labelClass} htmlFor="lead-whatsapp">واتساب<input className={inputClass} dir="ltr" disabled={pending} id="lead-whatsapp" name="whatsapp" placeholder="+201..." /></label>
        <label className={labelClass} htmlFor="lead-email">البريد الإلكتروني<input className={inputClass} dir="ltr" disabled={pending} id="lead-email" name="email" type="email" /></label>
        <label className={labelClass} htmlFor="lead-source">المصدر<select className={inputClass} defaultValue="website" disabled={pending} id="lead-source" name="source"><option value="website">الموقع</option><option value="referral">إحالة</option><option value="walk_in">زيارة مباشرة</option><option value="whatsapp">واتساب</option><option value="other">مصدر آخر</option></select></label>
        <label className={labelClass} htmlFor="lead-area">المنطقة المطلوبة<input className={inputClass} disabled={pending} id="lead-area" name="requested_area" placeholder="مثال: المعادي" /></label>
        <label className={labelClass} htmlFor="lead-in">الوصول المتوقع<input className={inputClass} disabled={pending} id="lead-in" name="requested_check_in" type="date" /></label>
        <label className={labelClass} htmlFor="lead-out">المغادرة المتوقعة<input className={inputClass} disabled={pending} id="lead-out" name="requested_check_out" type="date" /></label>
        <label className={labelClass} htmlFor="lead-guests">عدد الضيوف<input className={inputClass} disabled={pending} id="lead-guests" min="1" name="guests" type="number" /></label>
        <label className={labelClass} htmlFor="lead-bedrooms">غرف النوم<input className={inputClass} disabled={pending} id="lead-bedrooms" min="0" name="bedrooms" type="number" /></label>
        <label className={labelClass} htmlFor="lead-follow-up">موعد المتابعة<input className={inputClass} disabled={pending} id="lead-follow-up" name="next_follow_up_at" type="datetime-local" /></label>
        <label className={labelClass} htmlFor="lead-budget">ميزانية مكتوبة <span className="font-normal text-muted">(اختياري)</span><input className={inputClass} disabled={pending} id="lead-budget" maxLength={200} name="budget_text" placeholder="كما ذكرها العميل" /></label>
      </div>
      <label className={`${labelClass} mt-4 block`} htmlFor="lead-notes">ملاحظات الطلب <span className="font-normal text-muted">(اختياري)</span><textarea className="mt-2 min-h-20 w-full rounded-xl border border-[#c9d9d3] bg-white p-3 text-sm font-normal text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" disabled={pending} id="lead-notes" maxLength={4000} name="notes" /></label>

      <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-[#d4dfda] pt-4">
        <p className="text-[11px] leading-5 text-muted">تحذير التكرار يظهر للمراجعة فقط؛ لا يتم الدمج تلقائيًا.</p>
        <button className="flex h-11 items-center gap-2 rounded-xl bg-harbor px-5 text-sm font-bold text-white hover:bg-tide disabled:bg-[#78938c]" disabled={pending} type="submit">{pending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin" /> : <Plus aria-hidden="true" className="size-4" />}إضافة الطلب</button>
      </div>
      {state.status !== "idle" ? <p aria-live="polite" className={`mt-3 flex gap-2 text-xs ${state.status === "success" ? "text-tide" : "text-coral"}`}><CircleAlert aria-hidden="true" className="size-4" />{state.message}</p> : null}
    </form>
  );
}
