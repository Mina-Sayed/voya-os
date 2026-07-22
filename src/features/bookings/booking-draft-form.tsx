"use client";

import { CalendarPlus, CircleAlert, LoaderCircle } from "lucide-react";
import { useActionState, useState } from "react";

export type BookingDraftState = Readonly<{ status: "idle" | "success" | "invalid" | "denied" | "retry"; message: string }>;
export type BookingDraftAction = (previousState: BookingDraftState, formData: FormData) => Promise<BookingDraftState>;
export type BookingDraftOption = Readonly<{ id: string; label: string }>;

const initialState: BookingDraftState = { status: "idle", message: "" };

export function BookingDraftForm({ createDraft, properties, clients }: Readonly<{ createDraft: BookingDraftAction; properties: readonly BookingDraftOption[]; clients: readonly BookingDraftOption[] }>) {
  const [state, formAction, isPending] = useActionState(createDraft, initialState);
  const [idempotencyKey] = useState(() => crypto.randomUUID());
  const isReady = properties.length > 0 && clients.length > 0;
  return (
    <form action={formAction} className="rounded-[1.75rem] border border-[#d4dfda] bg-[#f0f7f4] p-5 shadow-[0_18px_44px_rgba(16,33,38,0.04)] sm:p-7">
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="flex items-start gap-3"><div className="grid size-10 place-items-center rounded-xl bg-harbor text-sea-glass"><CalendarPlus aria-hidden="true" className="size-5" /></div><div><p className="text-[11px] font-bold tracking-[0.08em] text-tide">طلب تشغيل</p><h1 className="mt-1 text-2xl font-bold tracking-[-0.08em] text-harbor">مسودة حجز</h1><p className="mt-2 text-sm leading-6 text-muted">يُسجل هذا الطلب كمسودة فقط. لا يؤكد التوفر ولا ينشئ سعراً أو دفعة.</p></div></div>
      <div className="mt-6 grid gap-4 sm:grid-cols-2">
        <label className="text-xs font-bold text-harbor" htmlFor="booking-property">العقار<select className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-3 text-sm font-normal text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" defaultValue="" disabled={isPending || !isReady} id="booking-property" name="property_id" required><option disabled value="">اختر العقار</option>{properties.map((property) => <option key={property.id} value={property.id}>{property.label}</option>)}</select></label>
        <label className="text-xs font-bold text-harbor" htmlFor="booking-client">العميل<select className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-3 text-sm font-normal text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" defaultValue="" disabled={isPending || !isReady} id="booking-client" name="client_id" required><option disabled value="">اختر العميل</option>{clients.map((client) => <option key={client.id} value={client.id}>{client.label}</option>)}</select></label>
        <label className="text-xs font-bold text-harbor" htmlFor="booking-check-in">تاريخ الوصول<input className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-3 text-sm font-normal text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" disabled={isPending || !isReady} id="booking-check-in" name="check_in" required type="date" /></label>
        <label className="text-xs font-bold text-harbor" htmlFor="booking-check-out">تاريخ المغادرة<input className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-3 text-sm font-normal text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" disabled={isPending || !isReady} id="booking-check-out" name="check_out" required type="date" /></label>
      </div>
      {!isReady ? <p className="mt-4 text-xs leading-6 text-coral">يلزم وجود عقار وعميل مسجلين قبل إنشاء المسودة.</p> : null}
      <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-[#d4dfda] pt-4"><p className="text-[11px] leading-5 text-muted">الوصول مشمول، والمغادرة غير مشمولة في مدة الإقامة.</p><button className="flex h-12 items-center gap-2 rounded-xl bg-harbor px-5 text-sm font-bold text-white disabled:cursor-not-allowed disabled:bg-[#78938c]" disabled={isPending || !isReady} type="submit">{isPending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <CalendarPlus aria-hidden="true" className="size-4" />}إنشاء مسودة الحجز</button></div>
      {state.status !== "idle" ? <p aria-live="polite" className={`mt-3 flex gap-2 text-xs leading-6 ${state.status === "success" ? "text-tide" : "text-coral"}`}><CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0" />{state.message}</p> : null}
    </form>
  );
}
