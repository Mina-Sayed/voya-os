"use client";

import { CircleAlert, CircleCheck, Clock3, LoaderCircle, ShieldCheck, Stamp } from "lucide-react";
import { useActionState } from "react";

export type ApprovalRequestItem = Readonly<{
  id: string;
  resourceType: string;
  resourceId: string;
  proposedAction: string;
  status: "pending" | "approved" | "rejected" | "expired" | "cancelled" | "executed";
  expiresAt: string | null;
  createdAt: string;
}>;
export type ApprovalActionState = Readonly<{ status: "idle" | "success" | "invalid" | "denied" | "retry"; message: string }>;
export type ApprovalDecisionAction = (previousState: ApprovalActionState, formData: FormData) => Promise<ApprovalActionState>;

const initialState: ApprovalActionState = { status: "idle", message: "" };
const actionCopy: Record<string, string> = {
  "booking.confirm": "تأكيد حجز",
  "booking.amend": "تعديل حجز",
  "booking.cancel": "إلغاء حجز",
};
const bookingApprovalActions = new Set(Object.keys(actionCopy));
const statusCopy = {
  pending: { label: "قيد المراجعة", Icon: Clock3, tone: "bg-[#fff6e8] text-[#9a6519]" },
  approved: { label: "مقبول", Icon: CircleCheck, tone: "bg-[#edf8f4] text-tide" },
  rejected: { label: "مرفوض", Icon: Clock3, tone: "bg-[#fff0eb] text-coral" },
  expired: { label: "منتهي", Icon: Clock3, tone: "bg-[#f1f0ed] text-muted" },
  cancelled: { label: "ملغي", Icon: Clock3, tone: "bg-[#f1f0ed] text-muted" },
  executed: { label: "نُفذ", Icon: CircleCheck, tone: "bg-[#edf8f4] text-tide" },
} as const;

function formatDate(value: string) {
  return new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
}

function DecisionForm({ request, action, decision }: Readonly<{ request: ApprovalRequestItem; action: ApprovalDecisionAction; decision: "approved" | "rejected" }>) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return <form action={formAction} className="mt-3 rounded-xl border border-line bg-[#f6faf7] p-3">
    <input name="approval_request_id" type="hidden" value={request.id} />
    <input name="decision" type="hidden" value={decision} />
    <label className="text-[10px] font-bold text-harbor" htmlFor={`${decision}-${request.id}`}>
      سبب القرار
      <textarea className="mt-2 min-h-16 w-full rounded-xl border border-line bg-white p-2 text-xs text-ink outline-none focus:border-tide focus:ring-2 focus:ring-sea-glass/40" id={`${decision}-${request.id}`} maxLength={1000} name="reason" placeholder={decision === "approved" ? "تمت مراجعة التواريخ والطلب" : "اذكر سبب رفض التغيير"} required />
    </label>
    <button className={`mt-2 inline-flex min-h-10 items-center gap-1.5 rounded-xl px-3 text-[11px] font-bold text-white disabled:opacity-50 ${decision === "approved" ? "bg-tide hover:bg-harbor" : "bg-coral hover:bg-[#9f4d3c]"}`} disabled={pending} type="submit">
      {pending ? <LoaderCircle aria-hidden="true" className="size-3.5 animate-spin" /> : decision === "approved" ? <CircleCheck aria-hidden="true" className="size-3.5" /> : <CircleAlert aria-hidden="true" className="size-3.5" />}
      {decision === "approved" ? "اعتماد" : "رفض"}
    </button>
    {state.status !== "idle" ? <p aria-live="polite" className={`mt-2 text-[11px] font-semibold ${state.status === "success" ? "text-tide" : "text-coral"}`}>{state.message}</p> : null}
  </form>;
}

export function ApprovalRequestsPage({ requests, canDecide, decide }: Readonly<{ requests: readonly ApprovalRequestItem[]; canDecide: boolean; decide: ApprovalDecisionAction }>) {
  return <main className="min-h-screen bg-canvas px-4 py-5 text-ink sm:px-8 sm:py-8 lg:px-12">
    <div className="mx-auto max-w-4xl">
      <header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9">
        <div className="flex flex-wrap items-start justify-between gap-5">
          <div className="flex gap-4">
            <div className="grid size-12 shrink-0 place-items-center rounded-2xl bg-harbor text-sea-glass"><Stamp aria-hidden="true" className="size-6" /></div>
            <div><p className="text-[11px] font-bold tracking-[0.08em] text-tide">مسار المراجعة</p><h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">طلبات الموافقة</h1><p className="mt-3 max-w-xl text-sm leading-7 text-muted">راجع أثر القرار قبل اعتماده. أي تأكيد أو تعديل للحجز يعاد تفويضه على الخادم بعد اعتماد صالح.</p></div>
          </div>
          <div className="flex items-center gap-2 rounded-xl border border-[#d4dfda] bg-white/70 px-3 py-2 text-[11px] font-semibold text-tide"><ShieldCheck aria-hidden="true" className="size-4" />maker-checker</div>
        </div>
      </header>
      {requests.length === 0 ? <section className="mt-6 rounded-[1.75rem] border border-dashed border-[#bfd1cb] bg-surface px-6 py-14 text-center"><Stamp aria-hidden="true" className="mx-auto size-6 text-tide" /><h2 className="mt-5 text-xl font-bold text-harbor">لا توجد طلبات موافقة مرئية</h2></section> : <section aria-label="قائمة طلبات الموافقة" className="mt-6 space-y-3">
        {requests.map((request) => {
          const status = statusCopy[request.status];
          const StatusIcon = status.Icon;
          const canDecideRequest = canDecide && request.status === "pending" && bookingApprovalActions.has(request.proposedAction);
          return <article className="rounded-[1.4rem] border border-line bg-surface p-4 shadow-[0_8px_22px_rgba(16,33,38,0.03)]" key={request.id}>
            <div className="flex flex-wrap items-center gap-4">
              <div className={`grid size-9 shrink-0 place-items-center rounded-xl ${status.tone}`}><StatusIcon aria-hidden="true" className="size-4" /></div>
              <div className="min-w-0 flex-1"><h2 className="truncate text-sm font-bold text-harbor">{actionCopy[request.proposedAction] ?? request.proposedAction}</h2><p className="mt-1 text-[11px] text-muted">{request.resourceType} · <bdi className="font-mono" dir="ltr">{request.resourceId.slice(0, 8)}</bdi></p></div>
              <div className="shrink-0 text-end"><span className={`inline-flex rounded-full px-2 py-1 text-[10px] font-bold ${status.tone}`}>{status.label}</span><time className="mt-1 block font-mono text-[10px] text-muted" dateTime={request.createdAt}>{formatDate(request.createdAt)}</time></div>
            </div>
            {canDecideRequest ? <div className="mt-4 grid gap-3 border-t border-line pt-3 sm:grid-cols-2"><DecisionForm action={decide} decision="approved" request={request} /><DecisionForm action={decide} decision="rejected" request={request} /></div> : null}
          </article>;
        })}
      </section>}
    </div>
  </main>;
}
