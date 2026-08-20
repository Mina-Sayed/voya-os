"use client";

import { CircleAlert, LoaderCircle, Save } from "lucide-react";
import { useActionState } from "react";
import { useCommandForm } from "@/features/shared/use-command-form";
import type { PropertyOwnerListItem } from "./property-owners-page";
import type { PropertyOwnerMutationAction } from "./property-owner-command-state";

const initialState = { status: "idle" as const, message: "" };

export function PropertyOwnerEditForm({ owner, updateOwner }: Readonly<{ owner: PropertyOwnerListItem; updateOwner: PropertyOwnerMutationAction }>) {
  const [state, formAction, isPending] = useActionState(updateOwner, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return (
    <form action={formAction} className="mt-4 grid gap-3 border-t border-line pt-4" ref={formRef}>
      <input name="property_owner_id" type="hidden" value={owner.id} />
      <input name="expected_version" type="hidden" value={owner.version} />
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-xs font-bold text-harbor">الاسم<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={owner.displayName} disabled={isPending} name="display_name" required /></label>
        <label className="text-xs font-bold text-harbor">الحالة<select className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={owner.status === "archived" ? "inactive" : owner.status} disabled={isPending} name="status"><option value="active">نشط</option><option value="inactive">غير نشط</option></select></label>
        <label className="text-xs font-bold text-harbor">الهاتف<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={owner.phone ?? ""} disabled={isPending} name="phone" type="tel" /></label>
        <label className="text-xs font-bold text-harbor">واتساب<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={owner.whatsapp ?? ""} disabled={isPending} name="whatsapp" type="tel" /></label>
        <label className="text-xs font-bold text-harbor">البريد الإلكتروني<input className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={owner.email ?? ""} disabled={isPending} name="email" type="email" dir="ltr" /></label>
        <label className="text-xs font-bold text-harbor">وسيلة الاتصال المفضلة<select className="mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs" defaultValue={owner.preferredContactMethod ?? "none"} disabled={isPending} name="preferred_contact_method"><option value="none">غير محددة</option><option value="phone">الهاتف</option><option value="whatsapp">واتساب</option><option value="email">البريد الإلكتروني</option></select></label>
        <label className="text-xs font-bold text-harbor sm:col-span-2">ملاحظات<textarea className="mt-1 min-h-16 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 py-2 text-xs" defaultValue={owner.notes ?? ""} disabled={isPending} name="notes" /></label>
      </div>
      <button className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-harbor px-4 text-xs font-bold text-white disabled:opacity-60" disabled={isPending} type="submit">{isPending ? <LoaderCircle className="size-3.5 animate-spin" /> : <Save className="size-3.5" />}حفظ التعديل</button>
      {state.status !== "idle" ? <p aria-live="polite" className={`flex items-center gap-2 text-xs ${state.status === "success" ? "text-tide" : "text-coral"}`}>{state.status === "success" ? <Save className="size-3.5" /> : <CircleAlert className="size-3.5" />}{state.message}</p> : null}
    </form>
  );
}
