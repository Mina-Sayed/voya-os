"use client";

import { Archive, CircleAlert, LoaderCircle } from "lucide-react";
import { useActionState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";
import type { PropertyMutationAction } from "./property-command-state";

const initialState = { status: "idle" as const, message: "" };

export function PropertyArchiveForm({ propertyId, version, archiveProperty }: Readonly<{ propertyId: string; version: number; archiveProperty: PropertyMutationAction }>) {
  const [state, formAction, isPending] = useActionState(archiveProperty, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={formAction} className="mt-4 border-t border-line pt-4" ref={formRef}>
      <input name="property_id" type="hidden" value={propertyId} />
      <input name="expected_version" type="hidden" value={version} />
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <label className="text-xs font-bold text-harbor">سبب الأرشفة<textarea className="mt-2 min-h-20 w-full rounded-lg border border-[#e3c9c1] bg-white px-3 py-2 text-xs" disabled={isPending} name="reason" placeholder="مثال: لم يعد ضمن المخزون التشغيلي" required /></label>
      <button className="mt-3 inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-[#d9aaa0] px-4 text-xs font-bold text-[#9f493c] disabled:opacity-60" disabled={isPending} type="submit">{isPending ? <LoaderCircle className="size-3.5 animate-spin" /> : <Archive className="size-3.5" />}تأكيد الأرشفة</button>
      {state.status !== "idle" ? <p aria-live="polite" className={`mt-2 flex items-center gap-2 text-xs ${state.status === "success" ? "text-tide" : "text-coral"}`}><CircleAlert className="size-3.5" />{state.message}</p> : null}
    </form>
  );
}
