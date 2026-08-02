"use client";

import { CircleAlert, LoaderCircle, Plus } from "lucide-react";
import { useActionState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";

export type PropertyCreateState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
}>;

export type PropertyCreateAction = (
  previousState: PropertyCreateState,
  formData: FormData,
) => Promise<PropertyCreateState>;

type PropertyCreateFormProps = Readonly<{
  createProperty: PropertyCreateAction;
}>;

const initialState: PropertyCreateState = { status: "idle", message: "" };

export function PropertyCreateForm({ createProperty }: PropertyCreateFormProps) {
  const [state, formAction, isPending] = useActionState(createProperty, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);

  return (
    <form action={formAction} className="rounded-[1.5rem] border border-[#d4dfda] bg-[#f0f7f4] p-5 sm:p-6" ref={formRef}>
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="grid gap-4 sm:grid-cols-3">
        <div className="min-w-0">
          <label className="text-xs font-bold text-harbor" htmlFor="property-code">رمز العقار</label>
          <input autoComplete="off" className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 font-mono text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas" disabled={isPending} id="property-code" maxLength={80} name="code" placeholder="NILE-202" required type="text" dir="ltr" />
        </div>
        <div className="min-w-0">
          <label className="text-xs font-bold text-harbor" htmlFor="property-name">اسم العقار</label>
          <input autoComplete="off" className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas" disabled={isPending} id="property-name" maxLength={160} name="name" placeholder="مثال: شقة النيل" required type="text" />
        </div>
        <div className="min-w-0">
          <label className="text-xs font-bold text-harbor" htmlFor="property-timezone">المنطقة الزمنية</label>
          <input autoComplete="off" className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 font-mono text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas" defaultValue="Africa/Cairo" disabled={isPending} id="property-timezone" maxLength={80} name="timezone" required type="text" dir="ltr" />
        </div>
      </div>
      <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
        <p className="text-[11px] leading-5 text-muted">تأكد من رمز العقار والمنطقة الزمنية قبل الإضافة؛ لا تنشئ هذه العملية حجوزات أو بيانات مالية.</p>
        <button className="flex h-12 shrink-0 items-center justify-center gap-2 rounded-xl bg-harbor px-5 text-sm font-bold text-white shadow-[0_10px_22px_rgba(17,43,50,0.16)] transition hover:bg-tide disabled:cursor-not-allowed disabled:bg-[#78938c]" disabled={isPending} type="submit">
          {isPending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <Plus aria-hidden="true" className="size-4" />}
          إضافة العقار
        </button>
      </div>
      {state.status !== "idle" ? <p aria-live="polite" className={`mt-3 flex items-start gap-2 text-xs leading-6 ${state.status === "success" ? "text-tide" : "text-coral"}`}>{state.status === "success" ? <Plus aria-hidden="true" className="mt-1 size-3.5 shrink-0" /> : <CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0" />}{state.message}</p> : null}
    </form>
  );
}
