"use client";

import { useActionState, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { CheckCircle2, FileImage, LoaderCircle, LockKeyhole, Send, ShieldCheck, Sparkles, UploadCloud } from "lucide-react";
import { useCommandForm } from "@/features/shared/use-command-form";
import type { DataEntryActionState } from "@/app/workspace/ai/data-entry-actions";
import { DataEntryReview, type DataEntryDraftReview } from "./data-entry-review";

export type DataEntryDraftSummary = Readonly<{
  id: string;
  status: "collecting" | "queued" | "extracting" | "ready_for_review" | "confirmed" | "partially_applied" | "applied" | "rejected" | "expired" | "failed";
  sourceKind: "text" | "image" | "mixed";
  version: number;
  inputCount: number;
  createdAt: string;
}>;

export type DataEntryAction = (previousState: DataEntryActionState, formData: FormData) => Promise<DataEntryActionState>;

const initialState: DataEntryActionState = { status: "idle", message: "" };
const MAX_FILE_BYTES = 10 * 1024 * 1024;

const statusLabel: Record<DataEntryDraftSummary["status"], string> = {
  collecting: "تجميع البيانات",
  queued: "في قائمة الانتظار",
  extracting: "قيد الاستخراج",
  ready_for_review: "جاهزة للمراجعة",
  confirmed: "تم التأكيد",
  partially_applied: "تحتاج استكمالاً",
  applied: "تم الحفظ",
  rejected: "مرفوضة",
  expired: "منتهية",
  failed: "فشل الاستخراج",
};

function inputCountLabel(count: number): string {
  if (count === 0) return "بدون صور";
  if (count === 1) return "صورة واحدة مرفوعة";
  if (count === 2) return "صورتان مرفوعتان";
  return `${count} صور مرفوعة`;
}

function ActionFeedback({ state }: Readonly<{ state: DataEntryActionState }>) {
  if (state.status === "idle" || !state.message) return null;
  return <p aria-live="polite" className={`mt-3 text-[11px] font-semibold ${state.status === "success" ? "text-tide" : state.status === "denied" ? "text-coral" : "text-[#85652e]"}`}>{state.message}</p>;
}

export function DataEntryIntake({ confirmDraft, createDraft, drafts, rejectDraft, reviews = [], submitDraft }: Readonly<{ confirmDraft?: DataEntryAction; createDraft: DataEntryAction; drafts: readonly DataEntryDraftSummary[]; rejectDraft?: DataEntryAction; reviews?: readonly DataEntryDraftReview[]; submitDraft: DataEntryAction }>) {
  const router = useRouter();
  const uploadKeysRef = useRef(new Map<string, string>());
  const [activeDraftId, setActiveDraftId] = useState<string | null>(drafts[0]?.id ?? null);
  const createDraftAndSelect: DataEntryAction = async (previousState, formData) => {
    const nextState = await createDraft(previousState, formData);
    if (nextState.status === "success" && nextState.draftId) setActiveDraftId(nextState.draftId);
    return nextState;
  };
  const [createState, createFormAction, creating] = useActionState(createDraftAndSelect, initialState);
  const [submitState, submitFormAction, submitting] = useActionState(submitDraft, initialState);
  const { formRef: createFormRef, idempotencyKey: createIdempotencyKey } = useCommandForm(createState);
  const { formRef: submitFormRef, idempotencyKey: submitIdempotencyKey } = useCommandForm(submitState);
  const [uploading, setUploading] = useState(false);
  const [uploadMessage, setUploadMessage] = useState("");

  const selectedDraftId = activeDraftId ?? createState.draftId ?? drafts[0]?.id ?? null;
  const activeDraft = drafts.find((draft) => draft.id === selectedDraftId) ?? (createState.draftId === selectedDraftId ? {
    id: createState.draftId,
    status: "collecting" as const,
    sourceKind: "text" as const,
    version: 1,
    inputCount: 0,
    createdAt: new Date().toISOString(),
  } : null);

  async function uploadFiles(event: React.ChangeEvent<HTMLInputElement>) {
    const files = Array.from(event.target.files ?? []);
    if (!selectedDraftId || files.length === 0) return;
    const oversized = files.some((file) => file.size > MAX_FILE_BYTES);
    if (oversized) {
      setUploadMessage("بعض الملفات أكبر من الحد المسموح (10MB). لم يتم رفعها.");
      return;
    }
    setUploading(true);
    setUploadMessage("");
    let uploadedCount = 0;
    try {
      for (const file of files) {
        if (!["image/jpeg", "image/png", "image/webp"].includes(file.type)) {
          setUploadMessage("استخدم صور JPEG أو PNG أو WebP فقط.");
          continue;
        }
        const fileKey = `${selectedDraftId}:${file.name}:${file.size}:${file.lastModified}:${file.type}`;
        let idempotencyKey = uploadKeysRef.current.get(fileKey);
        if (!idempotencyKey) {
          idempotencyKey = crypto.randomUUID();
          uploadKeysRef.current.set(fileKey, idempotencyKey);
        }
        const response = await fetch(`/api/workspace/ai/data-entry/inputs?draft_id=${encodeURIComponent(selectedDraftId)}`, {
          method: "POST",
          headers: { "content-type": file.type, "x-idempotency-key": idempotencyKey },
          body: file,
        });
        if (!response.ok) {
          setUploadMessage("تعذر رفع إحدى الصور. راجع الحجم والصلاحيات ثم حاول مرة أخرى.");
          continue;
        }
        uploadKeysRef.current.delete(fileKey);
        uploadedCount += 1;
      }
      if (uploadedCount > 0) {
        setUploadMessage(`تم رفع ${uploadedCount} ${uploadedCount === 1 ? "صورة" : "صور"} خاصة للمسودة.`);
        router.refresh();
      }
    } catch {
      setUploadMessage("تعذر الاتصال بخدمة التخزين الخاصة الآن.");
    } finally {
      setUploading(false);
      event.target.value = "";
    }
  }

  return <section aria-labelledby="data-entry-heading" className="mt-10 rounded-[2rem] border border-[#d4dfda] bg-surface p-5 shadow-[0_12px_30px_rgba(16,33,38,0.04)] sm:p-7">
    <div className="flex flex-wrap items-start justify-between gap-4">
      <div className="flex gap-3"><div className="grid size-11 shrink-0 place-items-center rounded-2xl bg-harbor text-sea-glass"><Sparkles aria-hidden="true" className="size-5" /></div><div><p className="text-[10px] font-bold tracking-[0.08em] text-tide">مسار محكوم</p><h2 className="mt-1 text-2xl font-extrabold tracking-[-0.08em] text-harbor" id="data-entry-heading">إدخال بيانات بمساعدة Gemini</h2><p className="mt-2 max-w-2xl text-xs leading-6 text-muted">اكتب بيانات العملاء أو العقارات وارفع الصور المرجعية. يمكن تجهيز مسودة بالنص أو بالصور فقط، ولن يُحفظ أي عميل أو عقار قبل مراجعتك وتأكيدك.</p></div></div>
      <span className="inline-flex items-center gap-1.5 rounded-full bg-sea-glass px-3 py-1.5 text-[10px] font-bold text-tide"><ShieldCheck aria-hidden="true" className="size-3.5" />تأكيد بشري إلزامي</span>
    </div>

    <form action={createFormAction} className="mt-6 rounded-2xl border border-line bg-[#f8fbf9] p-4" ref={createFormRef}>
      <label className="text-[11px] font-bold text-harbor" htmlFor="data-entry-source-text">بيانات العملاء أو العقارات<textarea className="mt-2 min-h-28 w-full rounded-xl border border-line bg-white p-3 text-xs leading-6 text-ink outline-none focus:border-tide focus:ring-2 focus:ring-sea-glass/50" disabled={creating} id="data-entry-source-text" maxLength={20_000} name="source_text" placeholder="اختياري إذا كنت ستعتمد على الصور فقط. مثال: أحمد، هاتفه... أو 4 شقق في مصر الجديدة..." /></label>
      <input name="idempotency_key" type="hidden" value={createIdempotencyKey} />
      <button className="mt-3 inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-harbor px-4 text-xs font-bold text-white transition hover:bg-tide disabled:opacity-60" disabled={creating} type="submit">{creating ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin" /> : <Sparkles aria-hidden="true" className="size-4" />}تجهيز مسودة</button>
      <ActionFeedback state={createState} />
    </form>

    {activeDraft ? <div className="mt-5 rounded-2xl border border-[#dbe7e0] bg-[#f5faf7] p-4"><div className="flex flex-wrap items-start justify-between gap-3"><div><p className="text-[10px] font-bold text-tide">مسودة نشطة</p><p className="mt-1 font-mono text-[11px] text-muted" dir="ltr">{activeDraft.id}</p></div><span className="rounded-full bg-white px-2.5 py-1 text-[10px] font-bold text-tide">{statusLabel[activeDraft.status]}</span></div><div className="mt-4 grid gap-3 sm:grid-cols-2"><label className="flex cursor-pointer items-center gap-3 rounded-xl border border-dashed border-[#bfd1cb] bg-white px-3 py-3 text-[11px] font-bold text-harbor" htmlFor="data-entry-image-input"><UploadCloud aria-hidden="true" className="size-4 text-tide" />رفع صور مرجعية<input accept="image/jpeg,image/png,image/webp" aria-label="رفع صور مرجعية" className="sr-only" disabled={uploading || activeDraft.status !== "collecting"} id="data-entry-image-input" multiple onChange={uploadFiles} type="file" /></label><div className="rounded-xl bg-white px-3 py-3 text-[11px] text-muted"><FileImage aria-hidden="true" className="mb-1 size-4 text-tide" />{inputCountLabel(activeDraft.inputCount)}<span className="mt-1 block text-[10px]">JPEG / PNG / WebP · 10MB لكل ملف</span></div></div>{uploading ? <p className="mt-3 flex items-center gap-2 text-[11px] font-semibold text-tide"><LoaderCircle className="size-3.5 animate-spin" />جاري رفع الصور إلى التخزين الخاص...</p> : null}{uploadMessage ? <p aria-live="polite" className="mt-3 text-[11px] font-semibold text-[#85652e]">{uploadMessage}</p> : null}{activeDraft.status === "collecting" ? <form action={submitFormAction} className="mt-4 border-t border-[#dbe7e0] pt-4" ref={submitFormRef}><input name="draft_id" type="hidden" value={activeDraft.id} /><input name="idempotency_key" type="hidden" value={submitIdempotencyKey} /><button className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-tide px-4 text-[11px] font-bold text-white hover:bg-harbor disabled:opacity-60" disabled={submitting || uploading} type="submit">{submitting ? <LoaderCircle aria-hidden="true" className="size-3.5 animate-spin" /> : <Send aria-hidden="true" className="size-3.5" />}إرسال للاستخراج والمراجعة</button><ActionFeedback state={submitState} /></form> : null}</div> : <p className="mt-4 flex items-start gap-2 rounded-xl border border-line bg-[#f8fbf9] p-3 text-[11px] leading-5 text-muted"><LockKeyhole aria-hidden="true" className="mt-0.5 size-3.5 shrink-0 text-tide" />بعد تجهيز المسودة سيظهر هنا رفع الصور وزر الإرسال للمراجعة.</p>}
    {activeDraft && confirmDraft && rejectDraft ? (reviews.find((review) => review.id === activeDraft.id) ? <DataEntryReview confirmDraft={confirmDraft} rejectDraft={rejectDraft} review={reviews.find((review) => review.id === activeDraft.id)!} /> : null) : null}

    {drafts.length > 0 ? <div className="mt-6 border-t border-line pt-5"><p className="text-[10px] font-bold text-tide">المسودات الأخيرة</p><div className="mt-3 grid gap-2">{drafts.map((draft) => <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-line bg-white px-3 py-3" key={draft.id}><div><span className="text-[11px] font-bold text-harbor">{statusLabel[draft.status]}</span><span className="ms-2 text-[10px] text-muted">· {inputCountLabel(draft.inputCount)}</span></div>{draft.id !== selectedDraftId ? <button className="min-h-9 rounded-lg border border-line px-3 text-[10px] font-bold text-tide hover:border-tide" onClick={() => setActiveDraftId(draft.id)} type="button">متابعة المسودة</button> : <CheckCircle2 aria-hidden="true" className="size-4 text-tide" />}</div>)}</div></div> : null}
  </section>;
}
