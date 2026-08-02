"use client";

import { CalendarClock, CalendarPlus, CheckCircle2, CircleAlert, Clock3, LogIn, LogOut, ShieldCheck } from "lucide-react";
import { useActionState } from "react";
import type { BookingDraftAction, BookingDraftOption } from "./booking-draft-form";
import { BookingDraftForm } from "./booking-draft-form";
import { useCommandForm } from "@/features/shared/use-command-form";

export type BookingDraftListItem = Readonly<{
  id: string;
  propertyLabel: string;
  clientLabel: string;
  status: "draft" | "pending_approval" | "confirmed" | "cancelled" | "completed";
  checkIn: string;
  checkOut: string;
  hasCheckIn: boolean;
  hasCheckOut: boolean;
  createdAt: string;
}>;

export type BookingLifecycleActionState = Readonly<{ status: "idle" | "success" | "invalid" | "denied" | "retry"; message: string }>;
export type BookingLifecycleAction = (previousState: BookingLifecycleActionState, formData: FormData) => Promise<BookingLifecycleActionState>;
export type BookingStayAction = BookingLifecycleAction;

const initialState: BookingLifecycleActionState = { status: "idle", message: "" };
const statusCopy: Record<BookingDraftListItem["status"], { label: string; tone: string }> = {
  draft: { label: "مسودة", tone: "bg-[#fff8e9] text-[#85652e]" },
  pending_approval: { label: "في انتظار الاعتماد", tone: "bg-[#fff6e8] text-[#9a6519]" },
  confirmed: { label: "مؤكدة", tone: "bg-[#edf8f4] text-tide" },
  cancelled: { label: "ملغاة", tone: "bg-[#f1f0ed] text-muted" },
  completed: { label: "مكتملة", tone: "bg-[#edf8f4] text-tide" },
};

function formatDate(value: string) { return new Intl.DateTimeFormat("ar-EG", { day: "numeric", month: "short" }).format(new Date(value)); }

function ActionFeedback({ state }: Readonly<{ state: BookingLifecycleActionState }>) { return state.status === "idle" || !state.message ? null : <p aria-live="polite" className={`mt-2 text-[11px] font-semibold ${state.status === "success" ? "text-tide" : state.status === "denied" ? "text-coral" : "text-[#85652e]"}`}><CircleAlert aria-hidden="true" className="me-1 inline size-3.5" />{state.message}</p>; }

function BookingCommand({ bookingId, label, action, kind }: Readonly<{ bookingId: string; label: string; action: BookingLifecycleAction; kind: "approval" | "confirm" }>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={formAction} className="inline-flex" ref={formRef}><input name="booking_id" type="hidden" value={bookingId} /><input name="idempotency_key" type="hidden" value={idempotencyKey} /><button className={`inline-flex min-h-10 items-center gap-1.5 rounded-xl px-3 text-[11px] font-bold disabled:opacity-50 ${kind === "approval" ? "border border-[#d8c9a4] bg-white text-[#85652e] hover:bg-[#fff8e9]" : "bg-tide text-white hover:bg-harbor"}`} disabled={pending} type="submit">{kind === "approval" ? <ShieldCheck aria-hidden="true" className="size-3.5" /> : <CheckCircle2 aria-hidden="true" className="size-3.5" />}{label}</button><ActionFeedback state={state} /></form>;
}

function StayCommand({ bookingId, label, eventType, action }: Readonly<{ bookingId: string; label: string; eventType: "check_in" | "check_out"; action: BookingStayAction }>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={formAction} className="inline-flex" ref={formRef}><input name="booking_id" type="hidden" value={bookingId} /><input name="event_type" type="hidden" value={eventType} /><input name="idempotency_key" type="hidden" value={idempotencyKey} /><button className="inline-flex min-h-10 items-center gap-1.5 rounded-xl bg-harbor px-3 text-[11px] font-bold text-white hover:bg-tide disabled:opacity-50" disabled={pending} type="submit">{eventType === "check_in" ? <LogIn aria-hidden="true" className="size-3.5" /> : <LogOut aria-hidden="true" className="size-3.5" />}{label}</button><ActionFeedback state={state} /></form>;
}

function BookingCard({ booking, requestApproval, confirmBooking, recordStay, canOperateStay }: Readonly<{ booking: BookingDraftListItem; requestApproval: BookingLifecycleAction; confirmBooking: BookingLifecycleAction; recordStay: BookingStayAction; canOperateStay: boolean }>) {
  const status = statusCopy[booking.status];
  return <article className="rounded-2xl border border-[#e5e9e4] bg-[#fcfdfb] p-4"><div className="flex items-start justify-between gap-3"><div className="min-w-0"><p className="truncate text-sm font-extrabold text-[#173d35]">{booking.propertyLabel}</p><p className="mt-1 text-xs text-[#71817b]">{booking.clientLabel}</p></div><span className={`inline-flex shrink-0 items-center gap-1.5 rounded-full px-2.5 py-1 text-[10px] font-bold ${status.tone}`}><Clock3 aria-hidden="true" className="size-3" />{status.label}</span></div><div className="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-[#e7ebe6] pt-3 text-[11px] text-[#71817b]"><span className="font-mono" dir="ltr">{booking.checkIn} → {booking.checkOut}</span><time dateTime={booking.createdAt}>{formatDate(booking.createdAt)}</time></div><div className="mt-4 flex flex-wrap gap-2">{booking.status === "draft" ? <BookingCommand action={requestApproval} bookingId={booking.id} kind="approval" label="طلب اعتماد" /> : null}{booking.status === "pending_approval" ? <span className="inline-flex min-h-10 items-center gap-1.5 rounded-xl border border-[#e3d6b9] bg-[#fff8e9] px-3 text-[11px] font-bold text-[#85652e]"><Clock3 aria-hidden="true" className="size-3.5" />بانتظار قرار مالك أو مدير</span> : null}{booking.status === "pending_approval" ? <BookingCommand action={confirmBooking} bookingId={booking.id} kind="confirm" label="تأكيد بعد الاعتماد" /> : null}{booking.status === "confirmed" && canOperateStay && !booking.hasCheckIn ? <StayCommand action={recordStay} bookingId={booking.id} eventType="check_in" label="تسجيل الوصول" /> : null}{booking.status === "confirmed" && canOperateStay && booking.hasCheckIn && !booking.hasCheckOut ? <StayCommand action={recordStay} bookingId={booking.id} eventType="check_out" label="تسجيل المغادرة" /> : null}{booking.status === "confirmed" && booking.hasCheckIn ? <span className="inline-flex min-h-10 items-center rounded-xl bg-[#edf8f4] px-3 text-[11px] font-bold text-tide">تم تسجيل الوصول</span> : null}</div></article>;
}

export function BookingsPage({ properties, clients, drafts, createDraft, requestApproval, confirmBooking, recordStay, canOperateStay }: Readonly<{ properties: readonly BookingDraftOption[]; clients: readonly BookingDraftOption[]; drafts: readonly BookingDraftListItem[]; createDraft: BookingDraftAction; requestApproval: BookingLifecycleAction; confirmBooking: BookingLifecycleAction; recordStay: BookingStayAction; canOperateStay: boolean }>) {
  const active = drafts.filter((booking) => !["completed", "cancelled"].includes(booking.status)).length;
  return <main className="min-h-[calc(100vh-74px)] bg-[#fbfaf7] px-4 py-6 text-[#172a28] sm:px-7 sm:py-8 lg:px-9 lg:py-10"><div className="mx-auto max-w-[1120px]"><header className="flex flex-wrap items-end justify-between gap-5"><div><p className="text-xs font-bold text-[#a2742d]">سير عمل الإقامة</p><h1 className="mt-3 text-3xl font-extrabold tracking-[-0.09em] text-[#173d35] sm:text-4xl">الإقامات والحجوزات</h1><p className="mt-2 max-w-2xl text-sm leading-7 text-[#687b74]">من مسودة الطلب إلى الاعتماد والتأكيد ثم الوصول والمغادرة، مع بقاء كل قرار يدويًا وموثقًا.</p></div><div className="flex items-center gap-2 rounded-full border border-[#cfe3d9] bg-[#eef7f2] px-3 py-2 text-[11px] font-bold text-[#1a6958]"><CalendarClock aria-hidden="true" className="size-4" />{active} عمليات نشطة</div></header><div className="mt-8 grid gap-6 xl:grid-cols-[minmax(0,0.88fr)_minmax(0,1.12fr)]"><BookingDraftForm clients={clients} createDraft={createDraft} properties={properties} /><section aria-labelledby="booking-queue-heading" className="rounded-[1.75rem] border border-[#e1e5df] bg-white p-5 shadow-[0_10px_24px_rgba(26,52,45,0.035)] sm:p-7"><div className="flex items-start justify-between gap-4"><div><div className="flex items-center gap-2 text-[#1a6958]"><CalendarPlus aria-hidden="true" className="size-4" /><span className="text-[11px] font-bold">قائمة المتابعة</span></div><h2 className="mt-2 text-xl font-extrabold tracking-[-0.07em] text-[#173d35]" id="booking-queue-heading">آخر الإقامات</h2></div><span className="grid size-9 place-items-center rounded-xl bg-[#eef7f2] font-mono text-sm font-bold text-[#1a6958]">{drafts.length}</span></div>{drafts.length === 0 ? <div className="mt-7 rounded-2xl border border-dashed border-[#cfd9d2] bg-[#fcfdfb] px-5 py-12 text-center"><CalendarClock aria-hidden="true" className="mx-auto size-6 text-[#1a6958]" /><h3 className="mt-4 text-base font-extrabold text-[#173d35]">لا توجد إقامات بعد</h3><p className="mx-auto mt-2 max-w-sm text-xs leading-6 text-[#71817b]">بعد إنشاء أول مسودة ستظهر هنا لتتابع الاعتماد والوصول والمغادرة.</p></div> : <div className="mt-6 space-y-3">{drafts.map((booking) => <BookingCard booking={booking} canOperateStay={canOperateStay} confirmBooking={confirmBooking} key={booking.id} recordStay={recordStay} requestApproval={requestApproval} />)}</div>}<div className="mt-6 flex items-center gap-2 border-t border-[#e7ebe6] pt-4 text-[11px] text-[#71817b]"><CircleAlert aria-hidden="true" className="size-4 text-[#1a6958]" />لا توجد هنا أسعار أو دفعات أو refunds؛ هذه المرحلة تشغيل الإقامة فقط.</div></section></div></div></main>;
}
