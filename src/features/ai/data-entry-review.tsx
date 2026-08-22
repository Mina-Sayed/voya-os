"use client";

import { useActionState, useState } from "react";
import { AlertTriangle, CheckCircle2, CircleAlert, LoaderCircle, Save, ShieldCheck, Trash2 } from "lucide-react";
import { canConfirmDataEntryPayload, missingRequiredClientFields, missingRequiredPropertyFields, type DataEntryPayload } from "@/domain/ai/data-entry-contract";
import { useCommandForm } from "@/features/shared/use-command-form";
import type { DataEntryAction } from "./data-entry-intake";
import type { DataEntryActionState } from "@/app/workspace/ai/data-entry-actions";

export type DataEntryInputReview = Readonly<{
  id: string;
  mimeType: "image/jpeg" | "image/png" | "image/webp";
  byteSize: number;
  status: "active" | "mapped" | "archived";
  mappedPropertyId: string | null;
}>;

export type DataEntryDraftReview = Readonly<{
  id: string;
  status: "ready_for_review" | "partially_applied" | "confirmed" | "applied";
  version: number;
  sourceText: string;
  payload: DataEntryPayload;
  inputs: readonly DataEntryInputReview[];
}>;

const initialState: DataEntryActionState = { status: "idle", message: "" };

function Feedback({ state }: Readonly<{ state: DataEntryActionState }>) {
  if (state.status === "idle" || !state.message) return null;
  return <p aria-live="polite" className={`mt-3 text-[11px] font-semibold ${state.status === "success" ? "text-tide" : state.status === "denied" ? "text-coral" : "text-[#85652e]"}`}>{state.message}</p>;
}

function textValue(value: string | null): string {
  return value ?? "";
}

export function DataEntryReview({ confirmDraft, rejectDraft, review }: Readonly<{ confirmDraft: DataEntryAction; rejectDraft: DataEntryAction; review: DataEntryDraftReview }>) {
  const [payload, setPayload] = useState<DataEntryPayload>(review.payload);
  const [confirmState, confirmAction, confirming] = useActionState(confirmDraft, initialState);
  const [rejectState, rejectAction, rejecting] = useActionState(rejectDraft, initialState);
  const { formRef: confirmFormRef, idempotencyKey: confirmationKey } = useCommandForm(confirmState);
  const { formRef: rejectFormRef, idempotencyKey: rejectionKey } = useCommandForm(rejectState);
  const canConfirm = canConfirmDataEntryPayload(payload) && (payload.clients.length > 0 || payload.properties.length > 0);

  function updateClient(index: number, key: "displayName" | "phone" | "whatsapp" | "email" | "nationality" | "preferredLanguage" | "notes", nextValue: string) {
    setPayload((current) => ({ ...current, clients: current.clients.map((client, itemIndex) => itemIndex === index ? { ...client, [key]: nextValue || null } : client) }));
  }

  function updateProperty(index: number, key: "code" | "name" | "timezone" | "address" | "city" | "unitLabel" | "operationalNotes", nextValue: string) {
    setPayload((current) => ({ ...current, properties: current.properties.map((property, itemIndex) => itemIndex === index ? { ...property, [key]: nextValue || null } : property) }));
  }

  function toggleImage(propertyIndex: number, inputId: string, checked: boolean) {
    setPayload((current) => ({ ...current, properties: current.properties.map((property, itemIndex) => {
      if (itemIndex !== propertyIndex) return property;
      const imageInputIds = checked ? [...property.imageInputIds, inputId] : property.imageInputIds.filter((id) => id !== inputId);
      return { ...property, imageInputIds: [...new Set(imageInputIds)] };
    }) }));
  }

  return <section aria-labelledby={`review-${review.id}`} className="mt-6 rounded-[1.75rem] border border-[#d4dfda] bg-[#f5faf7] p-4 sm:p-6">
    <div className="flex flex-wrap items-start justify-between gap-3"><div><p className="text-[10px] font-bold tracking-[0.06em] text-tide">مسودة قابلة للتعديل</p><h3 className="mt-1 text-xl font-extrabold tracking-[-0.07em] text-harbor" id={`review-${review.id}`}>مراجعة مسودة الإدخال</h3><p className="mt-1 font-mono text-[10px] text-muted" dir="ltr">{review.id}</p></div><span className="inline-flex items-center gap-1.5 rounded-full bg-sea-glass px-2.5 py-1.5 text-[10px] font-bold text-tide"><ShieldCheck aria-hidden="true" className="size-3.5" />Gemini · اقتراح فقط</span></div>
    {review.status === "partially_applied" ? <p className="mt-4 flex items-start gap-2 rounded-xl border border-[#ead9a8] bg-[#fff9e8] p-3 text-[11px] leading-5 text-[#765d22]"><AlertTriangle aria-hidden="true" className="mt-0.5 size-4 shrink-0" />تم حفظ جزء من المسودة. راجع العناصر المتبقية ثم أعد التأكيد.</p> : <p className="mt-4 flex items-start gap-2 rounded-xl border border-[#dbe7e0] bg-white/70 p-3 text-[11px] leading-5 text-muted"><CircleAlert aria-hidden="true" className="mt-0.5 size-4 shrink-0 text-tide" />لم يتم الحفظ بعد؛ هذه مسودة قابلة للتعديل.</p>}
    <details className="mt-4 rounded-xl border border-line bg-white/70 p-3"><summary className="cursor-pointer text-[11px] font-bold text-muted">عرض المصدر الذي أرسلته</summary><pre className="mt-3 max-h-48 overflow-auto whitespace-pre-wrap break-words text-[11px] leading-6 text-muted" dir="auto">{review.sourceText || "لم يُرسل نص؛ تم الاعتماد على الصور."}</pre></details>

    <form action={confirmAction} className="mt-5 space-y-4" ref={confirmFormRef}>
      {payload.clients.map((client, index) => <article className="rounded-2xl border border-[#dbe7e0] bg-white p-4" key={`client-${index}`}><div className="flex items-center justify-between gap-3"><h4 className="text-sm font-extrabold text-harbor">عميل {index + 1}</h4><span className="rounded-full bg-[#fff8e9] px-2 py-1 text-[10px] font-bold text-[#85652e]">ثقة {client.confidence}</span></div>{missingRequiredClientFields(client).length > 0 ? <p className="mt-2 text-[10px] font-bold text-coral">مطلوب: اسم العميل</p> : null}<div className="mt-3 grid gap-3 sm:grid-cols-2"><label className="text-[10px] font-bold text-harbor">اسم العميل<input aria-label={`اسم العميل ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" onChange={(event) => updateClient(index, "displayName", event.target.value)} value={textValue(client.displayName)} /></label><label className="text-[10px] font-bold text-harbor">الهاتف<input aria-label={`هاتف العميل ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" onChange={(event) => updateClient(index, "phone", event.target.value)} value={textValue(client.phone)} /></label><label className="text-[10px] font-bold text-harbor">البريد الإلكتروني<input aria-label={`بريد العميل ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" onChange={(event) => updateClient(index, "email", event.target.value)} value={textValue(client.email)} /></label><label className="text-[10px] font-bold text-harbor">الجنسية<input aria-label={`جنسية العميل ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" onChange={(event) => updateClient(index, "nationality", event.target.value)} value={textValue(client.nationality)} /></label></div></article>)}
      {payload.properties.map((property, index) => <article className="rounded-2xl border border-[#dbe7e0] bg-white p-4" key={`property-${index}`}><div className="flex items-center justify-between gap-3"><h4 className="text-sm font-extrabold text-harbor">عقار {index + 1}</h4><span className="rounded-full bg-[#fff8e9] px-2 py-1 text-[10px] font-bold text-[#85652e]">ثقة {property.confidence}</span></div>{missingRequiredPropertyFields(property).length > 0 ? <p className="mt-2 text-[10px] font-bold text-coral">مطلوب: {missingRequiredPropertyFields(property).join("، ")}</p> : null}<div className="mt-3 grid gap-3 sm:grid-cols-2"><label className="text-[10px] font-bold text-harbor">كود العقار<input aria-label={`كود العقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" onChange={(event) => updateProperty(index, "code", event.target.value)} value={textValue(property.code)} /></label><label className="text-[10px] font-bold text-harbor">اسم العقار<input aria-label={`اسم العقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" onChange={(event) => updateProperty(index, "name", event.target.value)} value={textValue(property.name)} /></label><label className="text-[10px] font-bold text-harbor">المنطقة أو المدينة<input aria-label={`مدينة العقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" onChange={(event) => updateProperty(index, "city", event.target.value)} value={textValue(property.city)} /></label><label className="text-[10px] font-bold text-harbor">العنوان<input aria-label={`عنوان العقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" onChange={(event) => updateProperty(index, "address", event.target.value)} value={textValue(property.address)} /></label><label className="text-[10px] font-bold text-harbor">المنطقة الزمنية<input aria-label={`المنطقة الزمنية للعقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" onChange={(event) => updateProperty(index, "timezone", event.target.value)} value={textValue(property.timezone)} /></label></div>{review.inputs.length > 0 ? <fieldset className="mt-4 rounded-xl border border-dashed border-[#bfd1cb] p-3"><legend className="px-1 text-[10px] font-bold text-tide">الصور المرجعية لهذا العقار</legend><div className="grid gap-2 sm:grid-cols-2">{review.inputs.map((input) => <label className="flex items-center gap-2 rounded-lg bg-[#f8fbf9] px-2 py-2 text-[10px] text-muted" htmlFor={`image-${index}-${input.id}`} key={input.id}><input checked={property.imageInputIds.includes(input.id)} id={`image-${index}-${input.id}`} aria-label={`ربط الصورة ${input.id} بالعقار ${index}`} disabled={input.status === "mapped" && input.mappedPropertyId !== null} onChange={(event) => toggleImage(index, input.id, event.target.checked)} type="checkbox" /><span>صورة <bdi dir="ltr">{input.id.slice(0, 8)}</bdi> · {Math.ceil(input.byteSize / 1024)}KB</span></label>)}</div></fieldset> : null}</article>)}
      {payload.unresolved.length > 0 ? <section className="rounded-2xl border border-[#ead9a8] bg-[#fff9e8] p-4"><h4 className="text-[11px] font-bold text-[#765d22]">حقائق تحتاج قرارًا</h4><ul className="mt-2 space-y-2">{payload.unresolved.map((item, index) => <li className="text-xs leading-6 text-[#765d22]" key={`${item.value}-${index}`}><bdi dir="auto">{item.value}</bdi> — {item.reason}</li>)}</ul></section> : null}
      <input name="draft_id" type="hidden" value={review.id} /><input name="expected_version" type="hidden" value={review.version} /><input name="confirmation_idempotency_key" type="hidden" value={confirmationKey} /><input name="payload_json" type="hidden" value={JSON.stringify(payload)} />
      <div className="flex flex-wrap items-center gap-2 border-t border-line pt-4"><button className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-tide px-4 text-[11px] font-bold text-white hover:bg-harbor disabled:cursor-not-allowed disabled:opacity-50" disabled={!canConfirm || confirming || rejecting} type="submit">{confirming ? <LoaderCircle aria-hidden="true" className="size-3.5 animate-spin" /> : <Save aria-hidden="true" className="size-3.5" />}تأكيد وحفظ</button><p className="text-[10px] text-muted">لن يتم تنفيذ الحفظ إلا عند الضغط على هذا الزر.</p></div><Feedback state={confirmState} />
    </form>
    <form action={rejectAction} className="mt-3" ref={rejectFormRef}><input name="draft_id" type="hidden" value={review.id} /><input name="expected_version" type="hidden" value={review.version} /><input name="idempotency_key" type="hidden" value={rejectionKey} /><button className="inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-[#e8c8bf] px-3 text-[10px] font-bold text-coral hover:bg-[#fff8f5] disabled:opacity-50" disabled={confirming || rejecting} type="submit"><Trash2 aria-hidden="true" className="size-3.5" />إلغاء المسودة وتنظيف الملفات</button><Feedback state={rejectState} /></form>
    {confirmState.status === "success" ? <p className="mt-4 flex items-center gap-2 text-[11px] font-bold text-tide"><CheckCircle2 aria-hidden="true" className="size-4" />تم تسجيل نتيجة الحفظ ويمكنك مراجعة السجلات في صفحات العملاء والعقارات.</p> : null}
  </section>;
}
