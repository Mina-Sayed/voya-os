"use client";

import { Archive, CircleAlert, ClipboardEdit, LoaderCircle, Save } from "lucide-react";
import { useActionState } from "react";
import type { CrmCommandAction, CrmCommandState } from "@/features/crm/crm-command-state";
import { useCommandForm } from "@/features/shared/use-command-form";
import type { ClientListItem } from "./client-types";

const initialState: CrmCommandState = { status: "idle", message: "" };
const inputClass = "mt-1 h-10 w-full rounded-lg border border-[#c9d9d3] bg-white px-3 text-xs text-ink outline-none focus:border-tide focus:ring-4 focus:ring-sea-glass/35 disabled:bg-canvas";
const labelClass = "text-[11px] font-bold text-harbor";

function Feedback({ state }: Readonly<{ state: CrmCommandState }>) {
  if (state.status === "idle" || !state.message) return null;
  return <p aria-live="polite" className={`mt-2 flex items-center gap-1.5 text-[11px] ${state.status === "success" ? "text-tide" : "text-coral"}`}><CircleAlert aria-hidden="true" className="size-3.5" />{state.message}</p>;
}

export function ClientEditForm({ client, updateClient }: Readonly<{ client: ClientListItem; updateClient: CrmCommandAction }>) {
  const [state, action, pending] = useActionState(updateClient, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={action} className="mt-4 border-t border-line pt-4" ref={formRef}><input name="client_id" type="hidden" value={client.id} /><input name="expected_version" type="hidden" value={client.version ?? 1} /><input name="idempotency_key" type="hidden" value={idempotencyKey} /><div className="grid gap-3 sm:grid-cols-2"><label className={labelClass}>الاسم<input className={inputClass} defaultValue={client.displayName} disabled={pending} name="display_name" required /></label><label className={labelClass}>الهاتف<input className={inputClass} defaultValue={client.phone ?? ""} dir="ltr" disabled={pending} name="phone" /></label><label className={labelClass}>واتساب<input className={inputClass} defaultValue={client.whatsapp ?? ""} dir="ltr" disabled={pending} name="whatsapp" /></label><label className={labelClass}>البريد<input className={inputClass} defaultValue={client.email ?? ""} dir="ltr" disabled={pending} name="email" type="email" /></label><label className={labelClass}>الجنسية<input className={inputClass} defaultValue={client.nationality ?? ""} disabled={pending} name="nationality" /></label><label className={labelClass}>اللغة<input className={inputClass} defaultValue={client.preferredLanguage ?? ""} disabled={pending} name="preferred_language" /></label></div><label className={`${labelClass} mt-3 block`}>ملاحظات<textarea className={`${inputClass} min-h-16 py-2`} defaultValue={client.notes ?? ""} disabled={pending} name="notes" /></label><button className="mt-3 inline-flex h-9 items-center gap-1.5 rounded-lg bg-harbor px-3 text-[11px] font-bold text-white disabled:opacity-60" disabled={pending} type="submit">{pending ? <LoaderCircle className="size-3.5 animate-spin" /> : <Save className="size-3.5" />}حفظ التعديل</button><Feedback state={state} /></form>;
}

export function ClientArchiveForm({ client, archiveClient }: Readonly<{ client: ClientListItem; archiveClient: CrmCommandAction }>) {
  const [state, action, pending] = useActionState(archiveClient, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form action={action} className="mt-4 border-t border-[#ead8d2] pt-4" ref={formRef}><input name="client_id" type="hidden" value={client.id} /><input name="expected_version" type="hidden" value={client.version ?? 1} /><input name="idempotency_key" type="hidden" value={idempotencyKey} /><label className={labelClass}>سبب الأرشفة<input className="mt-1 h-9 w-full rounded-lg border border-[#e3c9c1] bg-white px-2 text-[11px]" disabled={pending} name="reason" required /></label><button className="mt-2 inline-flex h-8 items-center gap-1 rounded-lg border border-[#d9aaa0] px-2.5 text-[10px] font-bold text-[#9f493c] disabled:opacity-60" disabled={pending} type="submit">{pending ? <LoaderCircle className="size-3 animate-spin" /> : <Archive className="size-3" />}أرشفة العميل</button><Feedback state={state} /></form>;
}

export function ClientEditIcon() { return <ClipboardEdit aria-hidden="true" className="size-3.5" />; }
