"use client";

import { CircleAlert, LoaderCircle, Plus } from "lucide-react";
import { useActionState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";

export type ClientCreateState = Readonly<{ status: "idle" | "success" | "invalid" | "denied" | "retry"; message: string }>;
export type ClientCreateAction = (previousState: ClientCreateState, formData: FormData) => Promise<ClientCreateState>;

const initialState: ClientCreateState = { status: "idle", message: "" };

export function ClientCreateForm({ createClient }: Readonly<{ createClient: ClientCreateAction }>) {
  const [state, formAction, isPending] = useActionState(createClient, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={formAction} className="rounded-[1.5rem] border border-[#d4dfda] bg-[#f0f7f4] p-5 sm:p-6" ref={formRef}>
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="flex flex-wrap items-end gap-4">
        <div className="min-w-0 flex-1">
          <label className="text-xs font-bold text-harbor" htmlFor="client-display-name">اسم العميل</label>
          <input autoComplete="name" className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas" disabled={isPending} id="client-display-name" maxLength={160} name="display_name" placeholder="مثال: عميل النيل" required type="text" />
        </div>
        <button className="flex h-12 shrink-0 items-center justify-center gap-2 rounded-xl bg-harbor px-5 text-sm font-bold text-white shadow-[0_10px_22px_rgba(17,43,50,0.16)] transition hover:bg-tide disabled:cursor-not-allowed disabled:bg-[#78938c]" disabled={isPending} type="submit">
          {isPending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <Plus aria-hidden="true" className="size-4" />}إضافة العميل
        </button>
      </div>
      <p className="mt-3 text-[11px] leading-5 text-muted">لا تظهر بيانات الاتصال في هذه المرحلة.</p>
      {state.status !== "idle" ? <p aria-live="polite" className={`mt-3 flex items-start gap-2 text-xs leading-6 ${state.status === "success" ? "text-tide" : "text-coral"}`}>{state.status === "success" ? <Plus aria-hidden="true" className="mt-1 size-3.5 shrink-0" /> : <CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0" />}{state.message}</p> : null}
    </form>
  );
}
