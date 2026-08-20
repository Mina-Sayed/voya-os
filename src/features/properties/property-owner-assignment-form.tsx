"use client";

import { CircleAlert, Link2, LoaderCircle } from "lucide-react";
import { useActionState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";
import type { PropertyMutationAction } from "./property-command-state";

type OwnerChoice = Readonly<{ id: string; displayName: string }>;

const initialState = { status: "idle" as const, message: "" };

export function PropertyOwnerAssignmentForm({ propertyId, owners, assignOwner }: Readonly<{ propertyId: string; owners: readonly OwnerChoice[]; assignOwner: PropertyMutationAction }>) {
  const [state, formAction, isPending] = useActionState(assignOwner, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={formAction} className="mt-4 border-t border-line pt-4" ref={formRef}>
      <input name="property_id" type="hidden" value={propertyId} />
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-xs font-bold text-harbor sm:col-span-2">المالك<select className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" disabled={isPending} name="property_owner_id" required><option value="">اختر مالكًا نشطًا</option>{owners.map((owner) => <option key={owner.id} value={owner.id}>{owner.displayName}</option>)}</select></label>
        <label className="text-xs font-bold text-harbor">بداية الربط<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" disabled={isPending} name="start_date" required type="date" /></label>
        <label className="text-xs font-bold text-harbor">نهاية الربط<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 font-mono text-xs" disabled={isPending} name="end_date" required type="date" /></label>
      </div>
      <label className="mt-3 flex items-center gap-2 text-xs font-semibold text-muted"><input className="size-4 accent-[#187a6b]" disabled={isPending} name="is_primary_contact" type="checkbox" />جهة الاتصال الأساسية لهذا النطاق</label>
      <button className="mt-3 inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-harbor px-4 text-xs font-bold text-white disabled:opacity-60" disabled={isPending} type="submit">{isPending ? <LoaderCircle className="size-3.5 animate-spin" /> : <Link2 className="size-3.5" />}حفظ ربط المالك</button>
      {state.status !== "idle" ? <p aria-live="polite" className={`mt-2 flex items-center gap-2 text-xs ${state.status === "success" ? "text-tide" : "text-coral"}`}><CircleAlert className="size-3.5" />{state.message}</p> : null}
    </form>
  );
}
