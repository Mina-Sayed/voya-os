"use client";

import Image from "next/image";
import { useActionState, useMemo, useState } from "react";
import { AlertTriangle, CheckCircle2, CircleAlert, LoaderCircle, Save, ShieldCheck, Trash2 } from "lucide-react";
import {
  DATA_ENTRY_EXCLUDED_BY_OPERATOR,
  excludedClientIndexes,
  excludedPropertyIndexes,
  successfulClientIndexes,
  successfulPropertyIndexes,
  type DataEntryApplicationResult,
} from "@/domain/ai/data-entry-application";
import {
  canConfirmDataEntryPayload,
  missingRequiredClientFields,
  missingRequiredPropertyFields,
  type DataEntryPayload,
} from "@/domain/ai/data-entry-contract";
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
  applicationResult?: DataEntryApplicationResult;
}>;

const initialState: DataEntryActionState = { status: "idle", message: "" };
const emptyApplicationResult: DataEntryApplicationResult = { clients: [], properties: [], images: [] };

function Feedback({ state }: Readonly<{ state: DataEntryActionState }>) {
  if (state.status === "idle" || !state.message) return null;
  return <p aria-live="polite" className={`mt-3 text-[11px] font-semibold ${state.status === "success" ? "text-tide" : state.status === "denied" ? "text-coral" : "text-[#85652e]"}`}>{state.message}</p>;
}

function textValue(value: string | null): string {
  return value ?? "";
}

function applicationErrorMessage(errorCode?: string): string | null {
  if (!errorCode || errorCode === DATA_ENTRY_EXCLUDED_BY_OPERATOR) return null;
  if (errorCode === "23505") return "توجد بيانات متعارضة مع سجل سبق حفظه. راجع القيم الفريدة قبل إعادة المحاولة.";
  if (errorCode === "23503") return "أحد السجلات المرتبطة لم يعد صالحًا. راجع المرجع أو الصورة ثم أعد المحاولة.";
  if (errorCode === "42501" || errorCode === "property_write_forbidden") return "صلاحياتك الحالية لا تسمح بحفظ هذا العقار.";
  if (errorCode === "22023" || errorCode === "22001") return "إحدى القيم غير صالحة أو تتجاوز الحد المسموح. راجع الحقول.";
  if (errorCode === "image_input_missing") return "صورة الإدخال لم تعد متاحة لهذه المسودة.";
  if (errorCode === "image_download_failed") return "تعذر قراءة صورة الإدخال الخاصة قبل الحفظ.";
  if (errorCode === "image_upload_failed") return "تعذر نسخ الصورة إلى صور العقار.";
  if (errorCode === "image_register_failed") return "تم نسخ الصورة لكن تعذر تسجيلها كسجل صورة للعقار.";
  if (errorCode === "image_map_failed") return "تعذر تثبيت ربط الصورة بالعقار بعد تسجيلها.";
  if (errorCode === "client_command_failed") return "تعذر حفظ العميل. راجع الحقول ثم أعد المحاولة.";
  if (errorCode === "property_command_failed") return "تعذر حفظ العقار. راجع الحقول ثم أعد المحاولة.";
  return `تعذر حفظ هذا العنصر (${errorCode}). راجع بياناته ثم أعد المحاولة.`;
}

function DataEntryTerminalReview({ review }: Readonly<{ review: DataEntryDraftReview }>) {
  const result = review.applicationResult ?? emptyApplicationResult;
  const appliedClients = result.clients.filter((item) => item.recordId).length;
  const appliedProperties = result.properties.filter((item) => item.recordId).length;
  return <section aria-labelledby={`review-${review.id}`} className="mt-6 rounded-[1.75rem] border border-[#d4dfda] bg-[#f5faf7] p-4 sm:p-6">
    <div className="flex items-start gap-3">
      <CheckCircle2 aria-hidden="true" className="mt-0.5 size-5 text-tide" />
      <div>
        <p className="text-[10px] font-bold tracking-[0.06em] text-tide">اكتمل الحفظ</p>
        <h3 className="mt-1 text-xl font-extrabold tracking-[-0.07em] text-harbor" id={`review-${review.id}`}>مراجعة مسودة الإدخال</h3>
        <p className="mt-2 text-[11px] leading-5 text-muted">هذه المسودة للقراءة فقط. تم حفظ {appliedClients} عميل و{appliedProperties} عقار.</p>
      </div>
    </div>
  </section>;
}

type DataEntryReviewProps = Readonly<{
  confirmDraft: DataEntryAction;
  rejectDraft: DataEntryAction;
  review: DataEntryDraftReview;
}>;

function DataEntryReviewForm({ confirmDraft, rejectDraft, review }: DataEntryReviewProps) {
  const [payload, setPayload] = useState<DataEntryPayload>(review.payload);
  const appliedResult = review.applicationResult ?? emptyApplicationResult;
  const appliedClients = useMemo(() => successfulClientIndexes(appliedResult), [appliedResult]);
  const appliedProperties = useMemo(() => successfulPropertyIndexes(appliedResult), [appliedResult]);
  const excludedClients = useMemo(() => excludedClientIndexes(appliedResult), [appliedResult]);
  const excludedProperties = useMemo(() => excludedPropertyIndexes(appliedResult), [appliedResult]);
  const clientResults = useMemo(() => new Map(appliedResult.clients.map((item) => [item.index, item] as const)), [appliedResult]);
  const propertyResults = useMemo(() => new Map(appliedResult.properties.map((item) => [item.index, item] as const)), [appliedResult]);
  const imageResults = useMemo(() => new Map(appliedResult.images.map((item) => [`${item.propertyIndex}:${item.inputId}`, item] as const)), [appliedResult]);
  const [includedClients, setIncludedClients] = useState<Set<number>>(() => new Set(review.payload.clients.map((_item, index) => index).filter((index) => !excludedClients.has(index))));
  const [includedProperties, setIncludedProperties] = useState<Set<number>>(() => new Set(review.payload.properties.map((_item, index) => index).filter((index) => !excludedProperties.has(index))));
  const [confirmState, confirmAction, confirming] = useActionState(confirmDraft, initialState);
  const [rejectState, rejectAction, rejecting] = useActionState(rejectDraft, initialState);
  const { formRef: confirmFormRef, idempotencyKey: confirmationKey } = useCommandForm(confirmState);
  const { formRef: rejectFormRef, idempotencyKey: rejectionKey } = useCommandForm(rejectState);

  const pendingSelected: DataEntryPayload = {
    ...payload,
    clients: payload.clients.filter((_item, index) => includedClients.has(index) && !appliedClients.has(index)),
    properties: payload.properties.filter((_item, index) => includedProperties.has(index) && !appliedProperties.has(index)),
  };
  const hasApplied = appliedClients.size > 0 || appliedProperties.size > 0 || appliedResult.images.some((item) => item.recordId);
  const hasTerminalChoice = hasApplied || excludedClients.size > 0 || excludedProperties.size > 0;
  const canConfirm = canConfirmDataEntryPayload(pendingSelected)
    && (pendingSelected.clients.length > 0 || pendingSelected.properties.length > 0 || hasTerminalChoice);

  function toggleIncluded(setter: React.Dispatch<React.SetStateAction<Set<number>>>, index: number) {
    setter((current) => {
      const next = new Set(current);
      if (next.has(index)) next.delete(index);
      else next.add(index);
      return next;
    });
  }

  function updateClient(index: number, key: "displayName" | "phone" | "whatsapp" | "email" | "nationality" | "preferredLanguage" | "notes" | "sourceLeadId", nextValue: string) {
    setPayload((current) => ({ ...current, clients: current.clients.map((client, itemIndex) => itemIndex === index ? { ...client, [key]: nextValue || null } : client) }));
  }

  function updateProperty(index: number, key: "code" | "name" | "timezone" | "address" | "city" | "unitLabel" | "operationalNotes", nextValue: string) {
    setPayload((current) => ({ ...current, properties: current.properties.map((property, itemIndex) => itemIndex === index ? { ...property, [key]: nextValue || null } : property) }));
  }

  function updatePropertyNumber(index: number, key: "bedrooms" | "maxGuests", nextValue: string) {
    setPayload((current) => ({ ...current, properties: current.properties.map((property, itemIndex) => itemIndex === index ? { ...property, [key]: nextValue === "" ? null : Number(nextValue) } : property) }));
  }

  function toggleImage(propertyIndex: number, inputId: string, checked: boolean) {
    setPayload((current) => ({
      ...current,
      properties: current.properties.map((property, itemIndex) => {
        const withoutInput = property.imageInputIds.filter((id) => id !== inputId);
        if (checked && itemIndex === propertyIndex) return { ...property, imageInputIds: [...withoutInput, inputId] };
        return { ...property, imageInputIds: withoutInput };
      }),
    }));
  }

  return <section aria-labelledby={`review-${review.id}`} className="mt-6 rounded-[1.75rem] border border-[#d4dfda] bg-[#f5faf7] p-4 sm:p-6">
    <div className="flex flex-wrap items-start justify-between gap-3"><div><p className="text-[10px] font-bold tracking-[0.06em] text-tide">مسودة قابلة للتعديل</p><h3 className="mt-1 text-xl font-extrabold tracking-[-0.07em] text-harbor" id={`review-${review.id}`}>مراجعة مسودة الإدخال</h3><p className="mt-1 font-mono text-[10px] text-muted" dir="ltr">{review.id}</p></div><span className="inline-flex items-center gap-1.5 rounded-full bg-sea-glass px-2.5 py-1.5 text-[10px] font-bold text-tide"><ShieldCheck aria-hidden="true" className="size-3.5" />Gemini · اقتراح فقط</span></div>
    {review.status === "partially_applied" ? <p className="mt-4 flex items-start gap-2 rounded-xl border border-[#ead9a8] bg-[#fff9e8] p-3 text-[11px] leading-5 text-[#765d22]"><AlertTriangle aria-hidden="true" className="mt-0.5 size-4 shrink-0" />تم حفظ جزء من المسودة. العناصر المكتملة مقفلة؛ راجع الأخطاء والعناصر المتبقية ثم أعد التأكيد.</p> : review.status === "confirmed" ? <p className="mt-4 flex items-start gap-2 rounded-xl border border-[#ead9a8] bg-[#fff9e8] p-3 text-[11px] leading-5 text-[#765d22]"><AlertTriangle aria-hidden="true" className="mt-0.5 size-4 shrink-0" />يوجد تنفيذ تأكيد سابق. إذا كان ما زال نشطًا سترفض قاعدة البيانات التنفيذ المكرر؛ وإذا انتهت مهلة الامتلاك يمكنك إعادة المحاولة من هنا لاستكمال المسودة.</p> : <p className="mt-4 flex items-start gap-2 rounded-xl border border-[#dbe7e0] bg-white/70 p-3 text-[11px] leading-5 text-muted"><CircleAlert aria-hidden="true" className="mt-0.5 size-4 shrink-0 text-tide" />لم يتم الحفظ بعد؛ هذه مسودة قابلة للتعديل.</p>}
    <details className="mt-4 rounded-xl border border-line bg-white/70 p-3"><summary className="cursor-pointer text-[11px] font-bold text-muted">عرض المصدر الذي أرسلته</summary><pre className="mt-3 max-h-48 overflow-auto whitespace-pre-wrap break-words text-[11px] leading-6 text-muted" dir="auto">{review.sourceText || "لم يُرسل نص؛ تم الاعتماد على الصور."}</pre></details>

    <form action={confirmAction} className="mt-5 space-y-4" ref={confirmFormRef}>
      {payload.clients.map((client, index) => {
        const applied = appliedClients.has(index);
        const included = includedClients.has(index);
        const disabled = applied || !included;
        const result = clientResults.get(index);
        const failureMessage = applicationErrorMessage(result?.errorCode);
        const wasExcluded = result?.errorCode === DATA_ENTRY_EXCLUDED_BY_OPERATOR;
        return <article className={`rounded-2xl border border-[#dbe7e0] bg-white p-4 ${disabled ? "opacity-70" : ""}`} key={`client-${index}`}>
          <div className="flex items-center justify-between gap-3"><h4 className="text-sm font-extrabold text-harbor">عميل {index + 1}</h4><div className="flex items-center gap-2">{applied ? <span className="rounded-full bg-sea-glass px-2 py-1 text-[10px] font-bold text-tide">تم الحفظ</span> : <button aria-label={included ? `استبعاد العميل ${index}` : `إعادة العميل ${index}`} className="rounded-lg border border-line px-2 py-1 text-[10px] font-bold text-tide" onClick={() => toggleIncluded(setIncludedClients, index)} type="button">{included ? "استبعاد" : "إعادة"}</button>}{wasExcluded && !included ? <span className="rounded-full bg-[#f2f3f3] px-2 py-1 text-[10px] font-bold text-muted">مستبعد سابقًا</span> : null}<span className="rounded-full bg-[#fff8e9] px-2 py-1 text-[10px] font-bold text-[#85652e]">ثقة {client.confidence}</span></div></div>
          {included && !applied && missingRequiredClientFields(client).length > 0 ? <p className="mt-2 text-[10px] font-bold text-coral">مطلوب: اسم العميل</p> : null}
          {failureMessage ? <p className="mt-2 rounded-lg bg-[#fff3ef] px-2 py-1.5 text-[10px] font-semibold leading-5 text-coral">{failureMessage}</p> : null}
          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <label className="text-[10px] font-bold text-harbor">اسم العميل<input aria-label={`اسم العميل ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} maxLength={160} onChange={(event) => updateClient(index, "displayName", event.target.value)} value={textValue(client.displayName)} /></label>
            <label className="text-[10px] font-bold text-harbor">الهاتف<input aria-label={`هاتف العميل ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateClient(index, "phone", event.target.value)} value={textValue(client.phone)} /></label>
            <label className="text-[10px] font-bold text-harbor">البريد الإلكتروني<input aria-label={`بريد العميل ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateClient(index, "email", event.target.value)} value={textValue(client.email)} /></label>
            <label className="text-[10px] font-bold text-harbor">الجنسية<input aria-label={`جنسية العميل ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateClient(index, "nationality", event.target.value)} value={textValue(client.nationality)} /></label>
            <label className="text-[10px] font-bold text-harbor">واتساب<input aria-label={`واتساب العميل ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateClient(index, "whatsapp", event.target.value)} value={textValue(client.whatsapp)} /></label>
            <label className="text-[10px] font-bold text-harbor">اللغة المفضلة<input aria-label={`اللغة المفضلة للعميل ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateClient(index, "preferredLanguage", event.target.value)} value={textValue(client.preferredLanguage)} /></label>
            <label className="text-[10px] font-bold text-harbor sm:col-span-2">معرّف العميل المحتمل<input aria-label={`معرّف العميل المحتمل ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 font-mono text-xs outline-none focus:border-tide" dir="ltr" disabled={disabled} onChange={(event) => updateClient(index, "sourceLeadId", event.target.value)} value={textValue(client.sourceLeadId)} /></label>
            <label className="text-[10px] font-bold text-harbor sm:col-span-2">ملاحظات<textarea aria-label={`ملاحظات العميل ${index}`} className="mt-1 min-h-20 w-full rounded-lg border border-line p-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateClient(index, "notes", event.target.value)} value={textValue(client.notes)} /></label>
          </div>
        </article>;
      })}

      {payload.properties.map((property, index) => {
        const applied = appliedProperties.has(index);
        const included = includedProperties.has(index);
        const disabled = applied || !included;
        const result = propertyResults.get(index);
        const failureMessage = applicationErrorMessage(result?.errorCode);
        const wasExcluded = result?.errorCode === DATA_ENTRY_EXCLUDED_BY_OPERATOR;
        return <article className={`rounded-2xl border border-[#dbe7e0] bg-white p-4 ${disabled ? "opacity-70" : ""}`} key={`property-${index}`}>
          <div className="flex items-center justify-between gap-3"><h4 className="text-sm font-extrabold text-harbor">عقار {index + 1}</h4><div className="flex items-center gap-2">{applied ? <span className="rounded-full bg-sea-glass px-2 py-1 text-[10px] font-bold text-tide">تم الحفظ</span> : <button aria-label={included ? `استبعاد العقار ${index}` : `إعادة العقار ${index}`} className="rounded-lg border border-line px-2 py-1 text-[10px] font-bold text-tide" onClick={() => toggleIncluded(setIncludedProperties, index)} type="button">{included ? "استبعاد" : "إعادة"}</button>}{wasExcluded && !included ? <span className="rounded-full bg-[#f2f3f3] px-2 py-1 text-[10px] font-bold text-muted">مستبعد سابقًا</span> : null}<span className="rounded-full bg-[#fff8e9] px-2 py-1 text-[10px] font-bold text-[#85652e]">ثقة {property.confidence}</span></div></div>
          {included && !applied && missingRequiredPropertyFields(property).length > 0 ? <p className="mt-2 text-[10px] font-bold text-coral">مطلوب: {missingRequiredPropertyFields(property).join("، ")}</p> : null}
          {failureMessage ? <p className="mt-2 rounded-lg bg-[#fff3ef] px-2 py-1.5 text-[10px] font-semibold leading-5 text-coral">{failureMessage}</p> : null}
          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <label className="text-[10px] font-bold text-harbor">كود العقار<input aria-label={`كود العقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateProperty(index, "code", event.target.value)} value={textValue(property.code)} /></label>
            <label className="text-[10px] font-bold text-harbor">اسم العقار<input aria-label={`اسم العقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateProperty(index, "name", event.target.value)} value={textValue(property.name)} /></label>
            <label className="text-[10px] font-bold text-harbor">المنطقة أو المدينة<input aria-label={`مدينة العقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateProperty(index, "city", event.target.value)} value={textValue(property.city)} /></label>
            <label className="text-[10px] font-bold text-harbor">العنوان<input aria-label={`عنوان العقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateProperty(index, "address", event.target.value)} value={textValue(property.address)} /></label>
            <label className="text-[10px] font-bold text-harbor">المنطقة الزمنية<input aria-label={`المنطقة الزمنية للعقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateProperty(index, "timezone", event.target.value)} value={textValue(property.timezone)} /></label>
            <label className="text-[10px] font-bold text-harbor">رقم أو اسم الوحدة<input aria-label={`رقم أو اسم وحدة العقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateProperty(index, "unitLabel", event.target.value)} value={textValue(property.unitLabel)} /></label>
            <label className="text-[10px] font-bold text-harbor">عدد غرف النوم<input aria-label={`عدد غرف نوم العقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} min={0} onChange={(event) => updatePropertyNumber(index, "bedrooms", event.target.value)} type="number" value={property.bedrooms ?? ""} /></label>
            <label className="text-[10px] font-bold text-harbor">الحد الأقصى للضيوف<input aria-label={`الحد الأقصى لضيوف العقار ${index}`} className="mt-1 h-10 w-full rounded-lg border border-line px-2 text-xs outline-none focus:border-tide" disabled={disabled} min={1} onChange={(event) => updatePropertyNumber(index, "maxGuests", event.target.value)} type="number" value={property.maxGuests ?? ""} /></label>
            <label className="text-[10px] font-bold text-harbor sm:col-span-2">ملاحظات التشغيل<textarea aria-label={`ملاحظات تشغيل العقار ${index}`} className="mt-1 min-h-20 w-full rounded-lg border border-line p-2 text-xs outline-none focus:border-tide" disabled={disabled} onChange={(event) => updateProperty(index, "operationalNotes", event.target.value)} value={textValue(property.operationalNotes)} /></label>
          </div>
          {review.inputs.length > 0 ? <fieldset className="mt-4 rounded-xl border border-dashed border-[#bfd1cb] p-3"><legend className="px-1 text-[10px] font-bold text-tide">الصور المرجعية لهذا العقار</legend><div className="grid gap-2 sm:grid-cols-2">{review.inputs.map((input) => {
            const imageResult = imageResults.get(`${index}:${input.id}`);
            const imageFailure = applicationErrorMessage(imageResult?.errorCode);
            const previewUrl = `/api/workspace/ai/data-entry/inputs/preview?draft_id=${encodeURIComponent(review.id)}&input_id=${encodeURIComponent(input.id)}`;
            return <label className="rounded-lg bg-[#f8fbf9] p-2 text-[10px] text-muted" htmlFor={`image-${index}-${input.id}`} key={input.id}>
              <Image alt={`معاينة صورة الإدخال ${input.id.slice(0, 8)}`} className="mb-2 h-28 w-full rounded-md border border-line object-cover" height={112} src={previewUrl} unoptimized width={180} />
              <span className="flex items-center gap-2"><input checked={property.imageInputIds.includes(input.id)} id={`image-${index}-${input.id}`} aria-label={`ربط الصورة ${input.id} بالعقار ${index}`} disabled={disabled || (input.status === "mapped" && input.mappedPropertyId !== null)} onChange={(event) => toggleImage(index, input.id, event.target.checked)} type="checkbox" /><span>صورة <bdi dir="ltr">{input.id.slice(0, 8)}</bdi> · {Math.ceil(input.byteSize / 1024)}KB</span></span>
              {imageFailure ? <span className="mt-1 block font-semibold leading-5 text-coral">{imageFailure}</span> : null}
            </label>;
          })}</div></fieldset> : null}
        </article>;
      })}

      {payload.unresolved.length > 0 ? <section className="rounded-2xl border border-[#ead9a8] bg-[#fff9e8] p-4"><h4 className="text-[11px] font-bold text-[#765d22]">حقائق تحتاج قرارًا</h4><ul className="mt-2 space-y-2">{payload.unresolved.map((item, index) => <li className="text-xs leading-6 text-[#765d22]" key={`${item.value}-${index}`}><bdi dir="auto">{item.value}</bdi> — {item.reason}</li>)}</ul></section> : null}
      {payload.warnings.length > 0 ? <section className="rounded-2xl border border-[#ead9a8] bg-[#fff9e8] p-4"><h4 className="text-[11px] font-bold text-[#765d22]">تنبيهات الاستخراج</h4><ul className="mt-2 list-inside list-disc space-y-2">{payload.warnings.map((warning, index) => <li className="text-xs leading-6 text-[#765d22]" key={`${warning}-${index}`}>{warning}</li>)}</ul></section> : null}

      <input name="draft_id" type="hidden" value={review.id} />
      <input name="expected_version" type="hidden" value={review.version} />
      <input name="confirmation_idempotency_key" type="hidden" value={confirmationKey} />
      <input name="payload_json" type="hidden" value={JSON.stringify(payload)} />
      <input name="included_client_indexes" type="hidden" value={JSON.stringify([...includedClients].sort((a, b) => a - b))} />
      <input name="included_property_indexes" type="hidden" value={JSON.stringify([...includedProperties].sort((a, b) => a - b))} />
      <div className="flex flex-wrap items-center gap-2 border-t border-line pt-4"><button className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-tide px-4 text-[11px] font-bold text-white hover:bg-harbor disabled:cursor-not-allowed disabled:opacity-50" disabled={!canConfirm || confirming || rejecting} type="submit">{confirming ? <LoaderCircle aria-hidden="true" className="size-3.5 animate-spin" /> : <Save aria-hidden="true" className="size-3.5" />}تأكيد وحفظ</button><p className="text-[10px] text-muted">لن يتم تنفيذ الحفظ إلا للعناصر المختارة عند الضغط على هذا الزر.</p></div>
      <Feedback state={confirmState} />
    </form>

    {review.status === "ready_for_review" ? <form action={rejectAction} className="mt-3" ref={rejectFormRef}><input name="draft_id" type="hidden" value={review.id} /><input name="expected_version" type="hidden" value={review.version} /><input name="idempotency_key" type="hidden" value={rejectionKey} /><button className="inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-[#e8c8bf] px-3 text-[10px] font-bold text-coral hover:bg-[#fff8f5] disabled:opacity-50" disabled={confirming || rejecting} type="submit"><Trash2 aria-hidden="true" className="size-3.5" />إلغاء المسودة وتنظيف الملفات</button><Feedback state={rejectState} /></form> : null}
    {confirmState.status === "success" ? <p className="mt-4 flex items-center gap-2 text-[11px] font-bold text-tide"><CheckCircle2 aria-hidden="true" className="size-4" />تم تسجيل نتيجة الحفظ ويمكنك مراجعة السجلات في صفحات العملاء والعقارات.</p> : null}
  </section>;
}

export function DataEntryReview(props: DataEntryReviewProps) {
  if (props.review.status === "applied") return <DataEntryTerminalReview review={props.review} key={props.review.id} />;
  return <DataEntryReviewForm {...props} key={props.review.id} />;
}
