"use client";

import { CircleAlert, LoaderCircle, Plus } from "lucide-react";
import { useActionState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";

export type PropertyOwnerCreateState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
}>;

export type PropertyOwnerCreateAction = (
  previousState: PropertyOwnerCreateState,
  formData: FormData,
) => Promise<PropertyOwnerCreateState>;

type PropertyOwnerCreateFormProps = Readonly<{
  createOwner: PropertyOwnerCreateAction;
}>;

const initialState: PropertyOwnerCreateState = { status: "idle", message: "" };

export function PropertyOwnerCreateForm({ createOwner }: PropertyOwnerCreateFormProps) {
  const [state, formAction, isPending] = useActionState(createOwner, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);

  return (
    <form action={formAction} className="rounded-[1.5rem] border border-[#d4dfda] bg-[#f0f7f4] p-5 sm:p-6" ref={formRef}>
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="min-w-0">
          <label className="text-xs font-bold text-harbor" htmlFor="property-owner-display-name">اسم المالك</label>
          <input autoComplete="organization" className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas" disabled={isPending} id="property-owner-display-name" maxLength={160} name="display_name" placeholder="مثال: شركة النخيل" required type="text" />
        </div>
        <label className="text-xs font-bold text-harbor">الهاتف<input autoComplete="tel" className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 text-sm text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" disabled={isPending} name="phone" type="tel" /></label>
        <label className="text-xs font-bold text-harbor">واتساب<input autoComplete="tel" className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 text-sm text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" disabled={isPending} name="whatsapp" type="tel" /></label>
        <label className="text-xs font-bold text-harbor">البريد الإلكتروني<input autoComplete="email" className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 text-sm text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" disabled={isPending} name="email" type="email" dir="ltr" /></label>
        <label className="text-xs font-bold text-harbor">وسيلة الاتصال المفضلة<select className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 text-sm text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" defaultValue="none" disabled={isPending} name="preferred_contact_method"><option value="none">غير محددة</option><option value="phone">الهاتف</option><option value="whatsapp">واتساب</option><option value="email">البريد الإلكتروني</option></select></label>
        <label className="text-xs font-bold text-harbor sm:col-span-2">ملاحظات<textarea className="mt-2 min-h-20 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 py-3 text-sm text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas" disabled={isPending} name="notes" /></label>
      </div>
      <div className="mt-4 flex flex-wrap items-end gap-4">
        <button className="flex h-12 shrink-0 items-center justify-center gap-2 rounded-xl bg-harbor px-5 text-sm font-bold text-white shadow-[0_10px_22px_rgba(17,43,50,0.16)] transition hover:bg-tide disabled:cursor-not-allowed disabled:bg-[#78938c]" disabled={isPending} type="submit">
          {isPending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin motion-reduce:animate-none" /> : <Plus aria-hidden="true" className="size-4" />}
          إضافة المالك
        </button>
      </div>
      {state.status !== "idle" ? (
        <p aria-live="polite" className={`mt-3 flex items-start gap-2 text-xs leading-6 ${state.status === "success" ? "text-tide" : "text-coral"}`}>
          {state.status === "success" ? <Plus aria-hidden="true" className="mt-1 size-3.5 shrink-0" /> : <CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0" />}
          {state.message}
        </p>
      ) : null}
    </form>
  );
}
