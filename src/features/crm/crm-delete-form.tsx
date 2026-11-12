"use client";

import { CircleAlert, LoaderCircle, Trash2 } from "lucide-react";
import { useActionState } from "react";
import type { CrmCommandAction, CrmCommandState } from "./crm-command-state";
import { useCommandForm } from "@/features/shared/use-command-form";

const initialState: CrmCommandState = { status: "idle", message: "" };

type CrmDeleteFormProps = Readonly<{
  kind: "lead" | "client";
  recordId: string;
  recordName: string;
  version: number;
  deleteRecord: CrmCommandAction;
}>;

/**
 * A deliberate, per-record destructive action, not bulk organization cleanup.
 * Names are checked again server-side and in the tenant-scoped database RPC.
 */
export function CrmDeleteForm({ kind, recordId, recordName, version, deleteRecord }: CrmDeleteFormProps) {
  const [state, action, pending] = useActionState(deleteRecord, initialState);
  const { formRef } = useCommandForm(state);
  const entityName = kind === "lead" ? "الطلب" : "العميل";

  return (
    <form action={action} className="mt-3 rounded-xl border border-[#d9aaa0] bg-[#fff7f5] p-3" ref={formRef}>
      <input name={kind === "lead" ? "lead_id" : "client_id"} type="hidden" value={recordId} />
      <input name="expected_version" type="hidden" value={version} />
      <p className="text-[11px] font-bold text-[#9f493c]">حذف {entityName} نهائيًا</p>
      <p className="mt-1 text-[10px] leading-5 text-muted">
        الحذف غير قابل للتراجع. السجلات المرتبطة بحجوزات أو أنشطة أو سجل CRM محمي لن تُحذف؛ استخدم الأرشفة بدلًا من ذلك.
      </p>
      <label className="mt-3 block text-[11px] font-bold text-harbor">
        اكتب اسم {entityName} للتأكيد: <bdi className="font-medium" dir="auto">{recordName}</bdi>
        <input
          autoComplete="off"
          className="mt-1 h-9 w-full rounded-lg border border-[#d9aaa0] bg-white px-2 text-xs text-ink outline-none focus:ring-2 focus:ring-[#d9aaa0]"
          disabled={pending}
          maxLength={160}
          name="confirm_name"
          required
          type="text"
        />
      </label>
      <button
        className="mt-3 inline-flex h-9 items-center gap-1.5 rounded-lg border border-[#b85a4f] bg-[#9f493c] px-3 text-[11px] font-bold text-white disabled:opacity-60"
        disabled={pending}
        type="submit"
      >
        {pending ? <LoaderCircle aria-hidden="true" className="size-3.5 animate-spin" /> : <Trash2 aria-hidden="true" className="size-3.5" />}
        تأكيد الحذف النهائي
      </button>
      {state.status !== "idle" && state.message ? (
        <p aria-live="polite" className={`mt-2 flex items-start gap-1.5 text-[11px] ${state.status === "success" ? "text-tide" : "text-coral"}`}>
          <CircleAlert aria-hidden="true" className="mt-0.5 size-3.5 shrink-0" />{state.message}
        </p>
      ) : null}
    </form>
  );
}
