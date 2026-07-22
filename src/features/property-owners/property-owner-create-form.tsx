"use client";

import { CircleAlert, LoaderCircle, Plus } from "lucide-react";
import { useActionState, useState } from "react";

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
  const [idempotencyKey] = useState(() => crypto.randomUUID());

  return (
    <form action={formAction} className="rounded-[1.5rem] border border-[#d4dfda] bg-[#f0f7f4] p-5 sm:p-6">
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="flex flex-wrap items-end gap-4">
        <div className="min-w-0 flex-1">
          <label className="text-xs font-bold text-harbor" htmlFor="property-owner-display-name">اسم المالك</label>
          <input
            autoComplete="organization"
            className="mt-2 h-12 w-full rounded-xl border border-[#c9d9d3] bg-white px-4 text-sm text-ink outline-none transition focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:cursor-not-allowed disabled:bg-canvas"
            disabled={isPending}
            id="property-owner-display-name"
            maxLength={160}
            name="display_name"
            placeholder="مثال: شركة النخيل"
            required
            type="text"
          />
        </div>
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
