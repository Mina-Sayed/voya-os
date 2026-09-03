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
  status: "draft" | "pending_approval" | "confirmed" | "checked_in" | "checked_out" | "cancelled" | "completed";
  checkIn: string;
  checkOut: string;
  amountMinor: string | null;
  currency: string | null;
  commercialCompletionStatus: "complete" | "needs_completion";
  version: number;
  hasCheckIn: boolean;
  hasCheckOut: boolean;
  createdAt: string;
  hasExecutableConfirmation?: boolean;
  latestApprovedAmendmentId?: string | null;
  latestApprovedCancellationId?: string | null;
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
  checked_in: { label: "داخل الإقامة", tone: "bg-[#edf8f4] text-tide" },
  checked_out: { label: "تمت المغادرة", tone: "bg-[#edf8f4] text-tide" },
};

function formatDate(value: string) { return new Intl.DateTimeFormat("ar-EG", { day: "numeric", month: "short" }).format(new Date(value)); }

function formatExactInteger(value: string) {
  if (!/^\d+$/u.test(value)) return value;
  try {
    return new Intl.NumberFormat("ar-EG").format(BigInt(value));
  } catch {
    return value;
  }
}

function ActionFeedback({ state }: Readonly<{ state: BookingLifecycleActionState }>) {
  return state.status === "idle" || !state.message ? null : <p aria-live="polite" className={`mt-2 text-[11px] font-semibold ${state.status === "success" ? "text-tide" : state.status === "denied" ? "text-coral" : "text-[#85652e]"}`}><CircleAlert aria-hidden="true" className="me-1 inline size-3.5" />{state.message}</p>;
}

function BookingCommand({ bookingId, approvalRequestId, label, action, kind }: Readonly<{ bookingId: string; approvalRequestId?: string | null; label: string; action: BookingLifecycleAction; kind: "approval" | "confirm" }>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={formAction} className="inline-flex flex-col items-start" ref={formRef}><input name="booking_id" type="hidden" value={bookingId} />{approvalRequestId ? <input name="approval_request_id" type="hidden" value={approvalRequestId} /> : null}<input name="idempotency_key" type="hidden" value={idempotencyKey} /><button className={`inline-flex min-h-10 items-center gap-1.5 rounded-xl px-3 text-[11px] font-bold disabled:opacity-50 ${kind === "approval" ? "border border-[#d8c9a4] bg-white text-[#85652e] hover:bg-[#fff8e9]" : "bg-tide text-white hover:bg-harbor"}`} disabled={pending} type="submit">{kind === "approval" ? <ShieldCheck aria-hidden="true" className="size-3.5" /> : <CheckCircle2 aria-hidden="true" className="size-3.5" />}{label}</button><ActionFeedback state={state} /></form>;
}

function StayCommand({ bookingId, label, eventType, action }: Readonly<{ bookingId: string; label: string; eventType: "check_in" | "check_out"; action: BookingStayAction }>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={formAction} className="inline-flex flex-col items-start" ref={formRef}><input name="booking_id" type="hidden" value={bookingId} /><input name="event_type" type="hidden" value={eventType} /><input name="idempotency_key" type="hidden" value={idempotencyKey} /><button className="inline-flex min-h-10 items-center gap-1.5 rounded-xl bg-harbor px-3 text-[11px] font-bold text-white hover:bg-tide disabled:opacity-50" disabled={pending} type="submit">{eventType === "check_in" ? <LogIn aria-hidden="true" className="size-3.5" /> : <LogOut aria-hidden="true" className="size-3.5" />}{label}</button><ActionFeedback state={state} /></form>;
}

function AmendmentForm({ booking, properties, clients, currency, action }: Readonly<{ booking: BookingDraftListItem; properties: readonly BookingDraftOption[]; clients: readonly BookingDraftOption[]; currency: string; action: BookingLifecycleAction }>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={formAction} className="mt-4 rounded-xl border border-[#d8c9a4] bg-[#fffaf0] p-3" ref={formRef}>
    <input name="booking_id" type="hidden" value={booking.id} />
    <input name="idempotency_key" type="hidden" value={idempotencyKey} />
    <p className="text-[10px] font-bold text-[#85652e]">طلب تعديل يحتاج اعتمادًا مستقلاً</p>
    <div className="mt-3 grid gap-3 sm:grid-cols-2">
      <label className="text-[10px] font-bold text-harbor">العقار<select className="mt-1 h-10 w-full rounded-lg border border-line bg-white px-2 text-xs" disabled={pending} name="property_id" required><option value="">اختر العقار</option>{properties.map((property) => <option key={property.id} value={property.id}>{property.label}</option>)}</select></label>
      <label className="text-[10px] font-bold text-harbor">العميل<select className="mt-1 h-10 w-full rounded-lg border border-line bg-white px-2 text-xs" disabled={pending} name="client_id" required><option value="">اختر العميل</option>{clients.map((client) => <option key={client.id} value={client.id}>{client.label}</option>)}</select></label>
      <label className="text-[10px] font-bold text-harbor">الوصول<input className="mt-1 h-10 w-full rounded-lg border border-line bg-white px-2 text-xs" defaultValue={booking.checkIn} disabled={pending} name="check_in" required type="date" /></label>
      <label className="text-[10px] font-bold text-harbor">المغادرة<input className="mt-1 h-10 w-full rounded-lg border border-line bg-white px-2 text-xs" defaultValue={booking.checkOut} disabled={pending} name="check_out" required type="date" /></label>
      <label className="text-[10px] font-bold text-harbor">المبلغ بالوحدة الصغرى<input className="mt-1 h-10 w-full rounded-lg border border-line bg-white px-2 text-xs" defaultValue={booking.amountMinor ?? ""} disabled={pending} min={0} name="amount_minor" required type="number" /></label>
      <label className="text-[10px] font-bold text-harbor">العملة<input className="mt-1 h-10 w-full rounded-lg border border-line bg-white px-2 text-xs" defaultValue={booking.currency ?? currency} disabled={pending} maxLength={3} name="currency" pattern="[A-Z]{3}" required /></label>
    </div>
    <label className="mt-3 block text-[10px] font-bold text-harbor">سبب التعديل<textarea className="mt-1 min-h-16 w-full rounded-lg border border-line bg-white p-2 text-xs" disabled={pending} maxLength={1000} name="reason" required /></label>
    <button className="mt-3 min-h-10 rounded-xl border border-[#d8c9a4] bg-white px-3 text-[11px] font-bold text-[#85652e] hover:bg-[#fff8e9] disabled:opacity-50" disabled={pending} type="submit">إرسال التعديل للاعتماد</button>
    <ActionFeedback state={state} />
  </form>;
}

function CancelDraftForm({ bookingId, action }: Readonly<{ bookingId: string; action: BookingLifecycleAction }>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={formAction} className="mt-4 rounded-xl border border-line bg-[#f6faf7] p-3" ref={formRef}>
    <input name="booking_id" type="hidden" value={bookingId} />
    <input name="idempotency_key" type="hidden" value={idempotencyKey} />
    <p className="text-[10px] font-bold text-harbor">إلغاء مباشر للمسودة دون اعتماد</p>
    <label className="mt-3 block text-[10px] font-bold text-harbor">سبب الإلغاء<textarea className="mt-1 min-h-16 w-full rounded-lg border border-line bg-white p-2 text-xs" disabled={pending} maxLength={1000} name="reason" required /></label>
    <button className="mt-3 min-h-10 rounded-xl border border-[#e5c4b8] bg-white px-3 text-[11px] font-bold text-coral hover:bg-[#fff0eb] disabled:opacity-50" disabled={pending} type="submit">إلغاء المسودة</button>
    <ActionFeedback state={state} />
  </form>;
}

function CancellationRequestForm({ bookingId, action }: Readonly<{ bookingId: string; action: BookingLifecycleAction }>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={formAction} className="mt-4 rounded-xl border border-[#d8c9a4] bg-[#fffaf0] p-3" ref={formRef}>
    <input name="booking_id" type="hidden" value={bookingId} />
    <input name="idempotency_key" type="hidden" value={idempotencyKey} />
    <p className="text-[10px] font-bold text-[#85652e]">طلب إلغاء يحتاج اعتمادًا مستقلاً (maker-checker)</p>
    <p className="mt-2 text-[10px] leading-5 text-[#85652e]">التنفيذ لاحقًا بواسطة مالك أو مدير مختلف عن مقدم الطلب. الأثر المالي للإلغاء (مبالغ مستردة/رسوم) غير محدد في V1.</p>
    <label className="mt-3 block text-[10px] font-bold text-harbor">سبب الإلغاء<textarea className="mt-1 min-h-16 w-full rounded-lg border border-line bg-white p-2 text-xs" disabled={pending} maxLength={1000} name="reason" required /></label>
    <button className="mt-3 min-h-10 rounded-xl border border-[#d8c9a4] bg-white px-3 text-[11px] font-bold text-[#85652e] hover:bg-[#fff8e9] disabled:opacity-50" disabled={pending} type="submit">إرسال الإلغاء للاعتماد</button>
    <ActionFeedback state={state} />
  </form>;
}

function BookingCard({ booking, properties, clients, currency, requestApproval, confirmBooking, requestAmendment, executeAmendment, cancelDraft, requestCancellation, executeCancellation, recordStay, canOperateStay, canApprove, canRequestAmendment }: Readonly<{ booking: BookingDraftListItem; properties: readonly BookingDraftOption[]; clients: readonly BookingDraftOption[]; currency: string; requestApproval: BookingLifecycleAction; confirmBooking: BookingLifecycleAction; requestAmendment?: BookingLifecycleAction; executeAmendment?: BookingLifecycleAction; cancelDraft?: BookingLifecycleAction; requestCancellation?: BookingLifecycleAction; executeCancellation?: BookingLifecycleAction; recordStay: BookingStayAction; canOperateStay: boolean; canApprove: boolean; canRequestAmendment: boolean }>) {
  const status = statusCopy[booking.status];
  const amount = booking.amountMinor ? formatExactInteger(booking.amountMinor) : null;
  return <article className="rounded-2xl border border-[#e5e9e4] bg-[#fcfdfb] p-4">
    <div className="flex items-start justify-between gap-3"><div className="min-w-0"><p className="truncate text-sm font-extrabold text-[#173d35]">{booking.propertyLabel}</p><p className="mt-1 text-xs text-[#71817b]">{booking.clientLabel}</p></div><span className={`inline-flex shrink-0 items-center gap-1.5 rounded-full px-2.5 py-1 text-[10px] font-bold ${status.tone}`}><Clock3 aria-hidden="true" className="size-3" />{status.label}</span></div>
    <div className="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-[#e7ebe6] pt-3 text-[11px] text-[#71817b]"><span className="font-mono" dir="ltr">{booking.checkIn} → {booking.checkOut}</span><span>{amount ? `${amount} ${booking.currency ?? ""}` : "السعر يحتاج استكمالًا"}</span><time dateTime={booking.createdAt}>{formatDate(booking.createdAt)}</time></div>
    {booking.commercialCompletionStatus === "needs_completion" ? <p className="mt-3 rounded-xl border border-[#ead9b8] bg-[#fff8e9] px-3 py-2 text-[11px] leading-5 text-[#85652e]">حجز تاريخي محفوظ كما هو. استكمل الـcommercial snapshot قبل أي اعتماد تجاري جديد.</p> : null}
    <div className="mt-4 flex flex-wrap gap-2">
      {booking.status === "draft" && booking.commercialCompletionStatus === "complete" ? <BookingCommand action={requestApproval} bookingId={booking.id} kind="approval" label="طلب اعتماد" /> : null}
      {booking.status === "pending_approval" && !booking.hasExecutableConfirmation ? <span className="inline-flex min-h-10 items-center gap-1.5 rounded-xl border border-[#e3d6b9] bg-[#fff8e9] px-3 text-[11px] font-bold text-[#85652e]"><Clock3 aria-hidden="true" className="size-3.5" />بانتظار قرار مالك أو مدير</span> : null}
      {booking.status === "pending_approval" && booking.hasExecutableConfirmation ? <span className="inline-flex min-h-10 items-center gap-1.5 rounded-xl bg-[#edf8f4] px-3 text-[11px] font-bold text-tide"><CheckCircle2 aria-hidden="true" className="size-3.5" />تم الاعتماد وجاهز للتأكيد</span> : null}
      {booking.status === "pending_approval" && canApprove && booking.hasExecutableConfirmation ? <BookingCommand action={confirmBooking} bookingId={booking.id} kind="confirm" label="تأكيد بعد الاعتماد" /> : null}
      {booking.status === "confirmed" && canOperateStay && !booking.hasCheckIn ? <StayCommand action={recordStay} bookingId={booking.id} eventType="check_in" label="تسجيل الوصول" /> : null}
      {booking.status === "checked_in" && canOperateStay && !booking.hasCheckOut ? <StayCommand action={recordStay} bookingId={booking.id} eventType="check_out" label="تسجيل المغادرة" /> : null}
      {booking.status === "checked_in" ? <span className="inline-flex min-h-10 items-center rounded-xl bg-[#edf8f4] px-3 text-[11px] font-bold text-tide">تم تسجيل الوصول</span> : null}
      {booking.status === "confirmed" && canApprove && executeAmendment && booking.latestApprovedAmendmentId ? <BookingCommand action={executeAmendment} approvalRequestId={booking.latestApprovedAmendmentId} bookingId={booking.id} kind="confirm" label="تطبيق تعديل معتمد" /> : null}
      {booking.status === "confirmed" && canApprove && executeCancellation && booking.latestApprovedCancellationId ? <BookingCommand action={executeCancellation} approvalRequestId={booking.latestApprovedCancellationId} bookingId={booking.id} kind="confirm" label="تنفيذ الإلغاء المعتمد" /> : null}
    </div>
    {booking.status === "draft" && canRequestAmendment && cancelDraft ? <CancelDraftForm action={cancelDraft} bookingId={booking.id} /> : null}
    {booking.status === "confirmed" && canRequestAmendment && requestAmendment ? <AmendmentForm action={requestAmendment} booking={booking} clients={clients} currency={currency} properties={properties} /> : null}
    {booking.status === "confirmed" && canRequestAmendment && requestCancellation ? <CancellationRequestForm action={requestCancellation} bookingId={booking.id} /> : null}
  </article>;
}

export function BookingsPage({ properties, clients, drafts, createDraft, requestApproval, confirmBooking, requestAmendment, executeAmendment, cancelDraft, requestCancellation, executeCancellation, recordStay, canOperateStay, canApprove, canRequestAmendment = true, currency }: Readonly<{ properties: readonly BookingDraftOption[]; clients: readonly BookingDraftOption[]; drafts: readonly BookingDraftListItem[]; createDraft: BookingDraftAction; requestApproval: BookingLifecycleAction; confirmBooking: BookingLifecycleAction; requestAmendment?: BookingLifecycleAction; executeAmendment?: BookingLifecycleAction; cancelDraft?: BookingLifecycleAction; requestCancellation?: BookingLifecycleAction; executeCancellation?: BookingLifecycleAction; recordStay: BookingStayAction; canOperateStay: boolean; canApprove: boolean; canRequestAmendment?: boolean; currency: string }>) {
  const active = drafts.filter((booking) => !["completed", "checked_out", "cancelled"].includes(booking.status)).length;
  return <main className="min-h-[calc(100vh-74px)] bg-[#fbfaf7] px-4 py-6 text-[#172a28] sm:px-7 sm:py-8 lg:px-9 lg:py-10"><div className="mx-auto max-w-[1120px]">
    <header className="flex flex-wrap items-end justify-between gap-5"><div><p className="text-xs font-bold text-[#a2742d]">سير عمل الإقامة التجاري</p><h1 className="mt-3 text-3xl font-extrabold tracking-[-0.09em] text-[#173d35] sm:text-4xl">الإقامات والحجوزات</h1><p className="mt-2 max-w-2xl text-sm leading-7 text-[#687b74]">من snapshot السعر إلى الاعتماد والتأكيد ثم الوصول والمغادرة، مع حفظ التاريخ القديم دون اختلاق أسعار.</p></div><div className="flex items-center gap-2 rounded-full border border-[#cfe3d9] bg-[#eef7f2] px-3 py-2 text-[11px] font-bold text-[#1a6958]"><CalendarClock aria-hidden="true" className="size-4" />{active} عمليات نشطة</div></header>
    <div className="mt-8 grid gap-6 xl:grid-cols-[minmax(0,0.88fr)_minmax(0,1.12fr)]"><BookingDraftForm clients={clients} createDraft={createDraft} currency={currency} properties={properties} /><section aria-labelledby="booking-queue-heading" className="rounded-[1.75rem] border border-[#e1e5df] bg-white p-5 shadow-[0_10px_24px_rgba(26,52,45,0.035)] sm:p-7"><div className="flex items-start justify-between gap-4"><div><div className="flex items-center gap-2 text-[#1a6958]"><CalendarPlus aria-hidden="true" className="size-4" /><span className="text-[11px] font-bold">قائمة المتابعة</span></div><h2 className="mt-2 text-xl font-extrabold tracking-[-0.07em] text-[#173d35]" id="booking-queue-heading">آخر الإقامات</h2></div><span className="grid size-9 place-items-center rounded-xl bg-[#eef7f2] font-mono text-sm font-bold text-[#1a6958]">{drafts.length}</span></div>{drafts.length === 0 ? <div className="mt-7 rounded-2xl border border-dashed border-[#cfd9d2] bg-[#fcfdfb] px-5 py-12 text-center"><CalendarClock aria-hidden="true" className="mx-auto size-6 text-[#1a6958]" /><h3 className="mt-4 text-base font-extrabold text-[#173d35]">لا توجد إقامات بعد</h3><p className="mx-auto mt-2 max-w-sm text-xs leading-6 text-muted">بعد إنشاء أول مسودة تجارية ستظهر هنا لتتابع الاعتماد والوصول والمغادرة.</p></div> : <div className="mt-6 space-y-3">{drafts.map((booking) => <BookingCard booking={booking} canApprove={canApprove} canOperateStay={canOperateStay} canRequestAmendment={canRequestAmendment} cancelDraft={cancelDraft} clients={clients} confirmBooking={confirmBooking} currency={currency} executeAmendment={executeAmendment} executeCancellation={executeCancellation} key={booking.id} properties={properties} recordStay={recordStay} requestAmendment={requestAmendment} requestApproval={requestApproval} requestCancellation={requestCancellation} />)}</div>}<div className="mt-6 flex items-center gap-2 border-t border-[#e7ebe6] pt-4 text-[11px] text-[#71817b]"><CircleAlert aria-hidden="true" className="size-4 text-[#1a6958]" />المبلغ المتفق عليه snapshot تجاري فقط؛ لا توجد دفعات أو refunds أو ledger في V1.</div></section></div>
  </div></main>;
}
