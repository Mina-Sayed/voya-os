"use client";

import { CircleAlert, LoaderCircle, Pencil, Trash2 } from "lucide-react";
import { useActionState } from "react";
import type { AvailabilityBlockAction, AvailabilityBlockState } from "./availability-block-create-form";

const initialState: AvailabilityBlockState = { status: "idle", message: "" };
const fieldClass = "mt-2 h-11 w-full rounded-xl border border-[#c9d9d3] bg-white px-3 text-sm font-normal text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35";

export type EditableAvailabilityBlock = Readonly<{ id: string; startDate: string; endDate: string; blockType: "maintenance" | "owner_use" | "administrative"; reason: string | null }>;

function StateMessage({ state }: Readonly<{ state: AvailabilityBlockState }>) {
  if (state.status === "idle") return null;
  return <p aria-live="polite" className={`mt-3 flex gap-2 text-xs leading-6 ${state.status === "success" ? "text-tide" : "text-coral"}`}><CircleAlert aria-hidden="true" className="mt-1 size-3.5 shrink-0" />{state.message}</p>;
}

export function AvailabilityBlockEditForm({ block, updateBlock, deleteBlock }: Readonly<{ block: EditableAvailabilityBlock; updateBlock: AvailabilityBlockAction; deleteBlock: AvailabilityBlockAction }>) {
  const [updateState, updateAction, isUpdating] = useActionState(updateBlock, initialState);
  const [deleteState, deleteAction, isDeleting] = useActionState(deleteBlock, initialState);
  const busy = isUpdating || isDeleting;
  return <details className="mt-4 border-t border-line pt-3"><summary className="cursor-pointer text-xs font-bold text-tide">تعديل أو حذف</summary>
    <form action={updateAction} className="mt-3">
      <input name="block_id" type="hidden" value={block.id} />
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="text-xs font-bold text-harbor">البداية<input className={fieldClass} defaultValue={block.startDate} disabled={busy} name="start_date" required type="date" /></label>
        <label className="text-xs font-bold text-harbor">النهاية<input className={fieldClass} defaultValue={block.endDate} disabled={busy} name="end_date" required type="date" /></label>
        <label className="text-xs font-bold text-harbor">النوع<select className={fieldClass} defaultValue={block.blockType} disabled={busy} name="block_type"><option value="maintenance">صيانة</option><option value="owner_use">استخدام المالك</option><option value="administrative">إداري</option></select></label>
      </div>
      <label className="mt-3 block text-xs font-bold text-harbor">السبب<textarea className="mt-2 min-h-16 w-full rounded-xl border border-[#c9d9d3] bg-white p-3 text-sm font-normal text-ink" defaultValue={block.reason ?? ""} disabled={busy} maxLength={500} name="reason" /></label>
      <button className="mt-3 flex h-10 items-center gap-2 rounded-xl bg-harbor px-4 text-xs font-bold text-white disabled:bg-[#78938c]" disabled={busy} type="submit">{isUpdating ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin" /> : <Pencil aria-hidden="true" className="size-4" />}حفظ التعديل</button>
      <StateMessage state={updateState} />
    </form>
    <form action={deleteAction} className="mt-3" onSubmit={(event) => { if (!window.confirm("حذف هذا الحظر؟")) event.preventDefault(); }}>
      <input name="block_id" type="hidden" value={block.id} />
      <button className="flex h-10 items-center gap-2 rounded-xl border border-coral px-4 text-xs font-bold text-coral disabled:opacity-60" disabled={busy} type="submit">{isDeleting ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin" /> : <Trash2 aria-hidden="true" className="size-4" />}حذف الحظر</button>
      <StateMessage state={deleteState} />
    </form>
  </details>;
}
