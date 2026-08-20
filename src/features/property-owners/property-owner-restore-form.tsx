"use client";

import { CircleAlert, History, LoaderCircle } from "lucide-react";
import { useActionState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";
import type { PropertyOwnerMutationAction } from "./property-owner-command-state";

const initialState = { status: "idle" as const, message: "" };

export function PropertyOwnerRestoreForm({ ownerId, version, restoreOwner }: Readonly<{ ownerId: string; version: number; restoreOwner: PropertyOwnerMutationAction }>) {
  const [state, formAction, isPending] = useActionState(restoreOwner, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={formAction} className="mt-4 border-t border-line pt-4" ref={formRef}>
      <input name="property_owner_id" type="hidden" value={ownerId} />
      <input name="expected_version" type="hidden" value={version} />
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <p className="text-xs leading-6 text-muted">الاستعادة تعيد المالك إلى حالة نشط دون إعادة اختراع أي تعيين.</p>
      <button className="mt-3 inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-[#bfd1cb] px-4 text-xs font-bold text-tide disabled:opacity-60" disabled={isPending} type="submit">{isPending ? <LoaderCircle className="size-3.5 animate-spin" /> : <History className="size-3.5" />}استعادة المالك</button>
      {state.status !== "idle" ? <p aria-live="polite" className={`mt-2 flex items-center gap-2 text-xs ${state.status === "success" ? "text-tide" : "text-coral"}`}><CircleAlert className="size-3.5" />{state.message}</p> : null}
    </form>
  );
}
