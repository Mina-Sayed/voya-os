"use client";

import { useActionState, useMemo, useState, type ReactNode } from "react";
import { AlertTriangle, Bot, CheckCircle2, CircleAlert, Clock3, EyeOff, LockKeyhole, Play, RotateCcw, ShieldCheck, Sparkles, Wrench } from "lucide-react";
import type { AgentDefinition } from "@/domain/ai/agent-registry";
import { useCommandForm } from "@/features/shared/use-command-form";
import { parseAiResult, type AiResultPresentation } from "./ai-result-presentation";
import { DataEntryIntake, type DataEntryDraftSummary } from "./data-entry-intake";
import type { DataEntryAction } from "@/features/ai/data-entry-intake";

export type AiToolCallItem = Readonly<{
  id: string;
  toolName: string;
  toolVersion: string;
  effect: "read" | "proposal";
  policyDecision: "allowed" | "denied";
  status: string;
  createdAt: string;
}>;

export type AiRunItem = Readonly<{
  id: string;
  agentKind: string;
  agentVersion: string;
  status: string;
  purpose: string;
  modelName: string;
  promptVersion: string;
  initiatedByMembershipId: string;
  createdAt: string;
  startedAt: string | null;
  finishedAt: string | null;
  errorCode: string | null;
  resultSummary: Readonly<{ provider: string; model: string; output: string }> | null;
  toolCalls: readonly AiToolCallItem[];
}>;

export type AiActionState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
}>;

export type AiAction = (previousState: AiActionState, formData: FormData) => Promise<AiActionState>;

const initialState: AiActionState = { status: "idle", message: "" };

const agentLabel: Record<string, string> = {
  copilot: "مساعد فُويا",
  sales: "مساعد المبيعات",
  booking: "مساعد الإقامات",
  finance: "مساعد المالية",
  manager: "ملخص المدير",
  data_entry: "مساعد إدخال البيانات",
};

const statusLabel: Record<string, string> = {
  queued: "في قائمة الانتظار",
  running: "قيد التشغيل",
  succeeded: "اكتمل",
  failed: "فشل مصنف",
  cancelled: "أُلغي",
  stopped: "أُوقف",
};

function ActionFeedback({ state }: Readonly<{ state: AiActionState }>) {
  if (state.status === "idle" || !state.message) return null;
  return <p aria-live="polite" className={`mt-2 text-[11px] font-semibold ${state.status === "success" ? "text-tide" : state.status === "denied" ? "text-coral" : "text-[#85652e]"}`}>{state.message}</p>;
}

function AgentRequestCard({ agent, requestRun }: Readonly<{ agent: AgentDefinition; requestRun: AiAction }>) {
  const [state, action] = useActionState(requestRun, initialState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  const disabled = agent.mode === "disabled";
  return (
    <article className={`rounded-[1.5rem] border p-5 ${disabled ? "border-line bg-[#f1f0ed] opacity-75" : "border-[#cfe3d9] bg-[#f5faf7]"}`}>
      <div className="flex items-start justify-between gap-3"><div className={`grid size-10 place-items-center rounded-xl ${disabled ? "bg-[#e1e0dc] text-muted" : "bg-sea-glass text-tide"}`}>{disabled ? <LockKeyhole aria-hidden="true" className="size-5" /> : <Bot aria-hidden="true" className="size-5" />}</div><span className={`rounded-full px-2.5 py-1 text-[10px] font-bold ${disabled ? "bg-white text-muted" : "bg-sea-glass text-tide"}`}>{disabled ? "غير مفعّل" : "وضع اقتراح"}</span></div>
      <h2 className="mt-5 text-base font-extrabold tracking-[-0.06em] text-harbor">{agent.label}</h2>
      <p className="mt-2 min-h-12 text-xs leading-6 text-muted">{agent.description}</p>
      {disabled ? <p className="mt-4 flex items-start gap-2 rounded-xl border border-line bg-white/70 p-3 text-[11px] leading-5 text-muted"><CircleAlert aria-hidden="true" className="mt-0.5 size-3.5 shrink-0 text-[#85652e]" />لن يُرسل أي طلب قبل اعتماد سياسة هذه الوصلة.</p> : <form action={action} className="mt-5 border-t border-[#dbe7e0] pt-4" ref={formRef}><input name="agent_kind" type="hidden" value={agent.kind} /><input name="idempotency_key" type="hidden" value={idempotencyKey} /><label className="text-[11px] font-bold text-harbor" htmlFor={`purpose-${agent.kind}`}>ما المطلوب؟<input className="mt-2 h-11 w-full rounded-xl border border-line bg-white px-3 text-xs outline-none focus:border-tide focus:ring-2 focus:ring-sea-glass/50" id={`purpose-${agent.kind}`} maxLength={280} name="purpose" placeholder="مثال: لخّص الطلبات التي تحتاج متابعة" required /></label><button className="mt-3 inline-flex min-h-11 w-full items-center justify-center gap-2 rounded-xl bg-harbor px-4 text-xs font-bold text-white hover:bg-tide" type="submit"><Play aria-hidden="true" className="size-4" />تسجيل طلب مساعدة</button><ActionFeedback state={state} /></form>}
    </article>
  );
}

function RunStatus({ status }: Readonly<{ status: string }>) {
  const icon = status === "succeeded" ? <CheckCircle2 aria-hidden="true" className="size-4" /> : status === "failed" ? <CircleAlert aria-hidden="true" className="size-4" /> : <Clock3 aria-hidden="true" className="size-4" />;
  return <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[10px] font-bold ${status === "succeeded" ? "bg-sea-glass text-tide" : status === "failed" ? "bg-[#fbe9e4] text-coral" : "bg-[#fff8e9] text-[#85652e]"}`}>{icon}{statusLabel[status] ?? status}</span>;
}

function ResultText({ children, className = "" }: Readonly<{ children: ReactNode; className?: string }>) {
  return <p dir="auto" className={`break-words text-xs leading-7 text-ink ${className}`}>{children}</p>;
}

function StructuredResult({ result }: Readonly<{ result: AiResultPresentation }>) {
  return <div className="mt-4 space-y-3">
    {result.partial ? <p className="flex items-start gap-2 rounded-xl border border-[#ead9a8] bg-[#fff9e8] p-3 text-[11px] leading-5 text-[#765d22]"><AlertTriangle aria-hidden="true" className="mt-0.5 size-4 shrink-0" />وصل الرد بشكل جزئي؛ تم عرض الأجزاء المكتملة فقط.</p> : null}
    {result.summary ? <section className="rounded-2xl border border-[#dbe7e0] bg-white/70 p-4"><p className="text-[10px] font-bold tracking-[0.06em] text-tide">الملخص</p><ResultText className="mt-1">{result.summary}</ResultText></section> : null}
    {result.suggestions.length > 0 ? <section className="rounded-2xl border border-[#dbe7e0] bg-white/70 p-4"><p className="text-[10px] font-bold tracking-[0.06em] text-tide">الاقتراحات</p><ol className="mt-2 space-y-2">{result.suggestions.map((suggestion, index) => <li className="flex items-start gap-2 text-xs leading-7 text-ink" key={`${suggestion}-${index}`}><span className="grid size-5 shrink-0 place-items-center rounded-full bg-sea-glass text-[10px] font-bold text-tide">{index + 1}</span><span dir="auto" className="break-words">{suggestion}</span></li>)}</ol></section> : null}
    {result.risks.length > 0 ? <section className="rounded-2xl border border-[#f0d8d1] bg-[#fff8f5] p-4"><p className="text-[10px] font-bold tracking-[0.06em] text-coral">مخاطر وملاحظات</p><ul className="mt-2 space-y-2">{result.risks.map((risk, index) => <li className="flex items-start gap-2 text-xs leading-7 text-ink" key={`${risk}-${index}`}><AlertTriangle aria-hidden="true" className="mt-1 size-4 shrink-0 text-coral" /><span dir="auto" className="break-words">{risk}</span></li>)}</ul></section> : null}
    {result.partial ? <details className="rounded-xl border border-line bg-white/50 p-3"><summary className="cursor-pointer text-[11px] font-bold text-muted">عرض النص المستلم</summary><pre dir="auto" className="mt-3 max-h-72 overflow-auto whitespace-pre-wrap break-words text-[11px] leading-6 text-muted">{result.raw}</pre></details> : null}
  </div>;
}

function AiResultCard({ resultSummary }: Readonly<{ resultSummary: NonNullable<AiRunItem["resultSummary"]> }>) {
  const result = parseAiResult(resultSummary.output);
  return <div className="mt-4 overflow-hidden rounded-2xl border border-[#dbe7e0] bg-[#f6faf7] p-3 sm:p-4">
    <div className="flex flex-wrap items-center justify-between gap-2"><span className="inline-flex items-center gap-1.5 text-[10px] font-bold text-tide"><Sparkles aria-hidden="true" className="size-3.5" />اقتراح من Gemini</span><bdi dir="ltr" className="rounded-full bg-white px-2.5 py-1 font-mono text-[10px] text-muted">{resultSummary.provider} · {resultSummary.model}</bdi></div>
    {result.kind === "structured" ? <StructuredResult result={result} /> : <details className="mt-4 rounded-xl border border-[#ead9a8] bg-[#fff9e8] p-3" open><summary className="cursor-pointer text-[11px] font-bold text-[#765d22]">النص المستلم</summary><pre dir="auto" className="mt-3 max-h-72 overflow-auto whitespace-pre-wrap break-words text-xs leading-7 text-ink">{result.raw}</pre></details>}
  </div>;
}

function RunCard({ run, onHide }: Readonly<{ run: AiRunItem; onHide: (runId: string) => void }>) {
  return <article className="rounded-[1.35rem] border border-line bg-surface p-5"><div className="flex flex-wrap items-start justify-between gap-3"><div className="min-w-0"><p className="text-[10px] font-bold text-tide">{agentLabel[run.agentKind] ?? run.agentKind} · {run.agentVersion}</p><h3 className="mt-2 break-words text-sm font-extrabold text-harbor">{run.purpose}</h3></div><div className="flex shrink-0 items-center gap-2"><RunStatus status={run.status} /><button aria-label={`إخفاء رد ${run.purpose}`} className="inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-line px-2.5 text-[10px] font-bold text-muted transition hover:border-coral hover:text-coral" onClick={() => onHide(run.id)} title="إخفاء الرد من هذا العرض" type="button"><EyeOff aria-hidden="true" className="size-3.5" /><span className="hidden sm:inline">إخفاء</span></button></div></div><div className="mt-4 grid gap-2 border-t border-line pt-3 text-[11px] text-muted sm:grid-cols-3"><span>النموذج: <bdi dir="ltr" className="font-mono text-ink">{run.modelName}</bdi></span><span>الأدوات: <bdi dir="ltr" className="font-mono text-ink">{run.toolCalls.length}</bdi></span><time dateTime={run.createdAt}>{new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium", timeStyle: "short", timeZone: "UTC" }).format(new Date(run.createdAt))}</time></div>{run.resultSummary ? <AiResultCard resultSummary={run.resultSummary} /> : null}{run.toolCalls.length > 0 ? <div className="mt-4 space-y-2 border-t border-line pt-3">{run.toolCalls.map((tool) => <div className="flex items-center justify-between gap-3 rounded-xl bg-[#f6faf7] px-3 py-2 text-[11px]" key={tool.id}><span className="inline-flex min-w-0 items-center gap-2 text-harbor"><Wrench aria-hidden="true" className="size-3.5 shrink-0 text-tide" /><bdi dir="ltr" className="truncate font-mono">{tool.toolName}</bdi></span><span className={`shrink-0 font-bold ${tool.policyDecision === "allowed" ? "text-tide" : "text-coral"}`}>{tool.policyDecision === "allowed" ? "مسموح" : "مرفوض"}</span></div>)}</div> : null}</article>;
}

export function AgentCenterPage({
  agents,
  runs,
  requestRun,
  dataEntryDrafts = [],
  dataEntryReviews = [],
  createDataEntryDraft,
  confirmDataEntryDraft,
  rejectDataEntryDraft,
  submitDataEntryDraft,
  canWriteDataEntryProperties = true,
}: Readonly<{ agents: readonly AgentDefinition[]; runs: readonly AiRunItem[]; requestRun: AiAction; dataEntryDrafts?: readonly DataEntryDraftSummary[]; dataEntryReviews?: readonly import("./data-entry-review").DataEntryDraftReview[]; createDataEntryDraft?: DataEntryAction; confirmDataEntryDraft?: DataEntryAction; rejectDataEntryDraft?: DataEntryAction; submitDataEntryDraft?: DataEntryAction; canWriteDataEntryProperties?: boolean }>) {
  const [hiddenRunIds, setHiddenRunIds] = useState<ReadonlySet<string>>(() => new Set());
  const visibleRuns = useMemo(() => runs.filter((run) => !hiddenRunIds.has(run.id)), [hiddenRunIds, runs]);
  const hiddenCount = runs.length - visibleRuns.length;
  const hideRun = (runId: string) => setHiddenRunIds((current) => new Set([...current, runId]));
  const restoreHiddenRuns = () => setHiddenRunIds(new Set());

  const dataEntryEnabled = agents.some((agent) => agent.kind === "data_entry") && createDataEntryDraft && submitDataEntryDraft;
  return <main className="min-h-[calc(100vh-74px)] bg-canvas px-4 py-6 text-ink sm:px-7 sm:py-8 lg:px-9 lg:py-10"><div className="mx-auto max-w-[1180px]"><header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9"><div className="flex flex-wrap items-start justify-between gap-5"><div className="flex gap-4"><div className="grid size-12 shrink-0 place-items-center rounded-2xl bg-harbor text-sea-glass"><Bot aria-hidden="true" className="size-6" /></div><div><p className="text-[11px] font-bold tracking-[0.08em] text-tide">مساعدة محكومة</p><h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">مركز الذكاء</h1><p className="mt-3 max-w-2xl text-sm leading-7 text-muted">تصل الطلبات إلى provider محكوم وتعود كاقتراحات منظمة قابلة للمراجعة؛ لا تُنفذ حجوزات أو مالية تلقائيًا.</p></div></div><div className="flex items-center gap-2 rounded-xl border border-[#d4dfda] bg-white/70 px-3 py-2 text-[11px] font-semibold text-tide"><ShieldCheck aria-hidden="true" className="size-4" />اقتراحات فقط</div></div><div className="mt-7 grid gap-3 border-t border-[#d4dfda] pt-5 sm:grid-cols-3"><div><p className="font-mono text-3xl font-medium text-harbor">{agents.filter((agent) => agent.mode === "preview").length}</p><p className="mt-1 text-xs text-muted">وصلات preview لدورك</p></div><div><p className="font-mono text-3xl font-medium text-tide">{visibleRuns.length}</p><p className="mt-1 text-xs text-muted">طلبات ظاهرة</p></div><div><p className="font-mono text-3xl font-medium text-[#85652e]">0</p><p className="mt-1 text-xs text-muted">تنفيذ تلقائي</p></div></div></header><section aria-labelledby="agent-registry-heading" className="mt-8"><div className="flex items-end justify-between gap-4"><div><p className="text-[11px] font-bold text-tide">الحدود</p><h2 className="mt-2 text-2xl font-extrabold tracking-[-0.08em] text-harbor" id="agent-registry-heading">الوكلاء المتاحون لدورك</h2></div><span className="rounded-full bg-sea-glass px-3 py-1.5 text-[11px] font-bold text-tide">server-owned</span></div><div className="mt-5 grid gap-5 lg:grid-cols-2">{agents.filter((agent) => agent.kind !== "data_entry").map((agent) => <AgentRequestCard agent={agent} key={agent.kind} requestRun={requestRun} />)}</div></section>{dataEntryEnabled ? <DataEntryIntake canWriteProperties={canWriteDataEntryProperties} confirmDraft={confirmDataEntryDraft} createDraft={createDataEntryDraft} drafts={dataEntryDrafts} rejectDraft={rejectDataEntryDraft} reviews={dataEntryReviews} submitDraft={submitDataEntryDraft} /> : null}<section aria-labelledby="run-history-heading" className="mt-10"><div className="flex flex-wrap items-end justify-between gap-4"><div><p className="text-[11px] font-bold text-tide">التتبع</p><h2 className="mt-2 text-2xl font-extrabold tracking-[-0.08em] text-harbor" id="run-history-heading">سجل طلبات الوكلاء</h2></div>{hiddenCount > 0 ? <button className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-line bg-surface px-3 py-2 text-[11px] font-bold text-muted hover:border-tide hover:text-tide" onClick={restoreHiddenRuns} type="button"><RotateCcw aria-hidden="true" className="size-3.5" />إظهار النتائج المخفية ({hiddenCount})</button> : <span className="rounded-full border border-line bg-surface px-3 py-1.5 text-[11px] font-bold text-muted">اقتراحات منظمة</span>}</div>{visibleRuns.length === 0 ? <div className="mt-5 rounded-[1.6rem] border border-dashed border-[#bfd1cb] bg-surface px-6 py-14 text-center"><Bot aria-hidden="true" className="mx-auto size-7 text-tide" /><h3 className="mt-4 text-lg font-extrabold text-harbor">{hiddenCount > 0 ? "أخفيت كل النتائج من هذا العرض" : "لم تُسجل طلبات بعد"}</h3><p className="mx-auto mt-2 max-w-md text-sm leading-7 text-muted">{hiddenCount > 0 ? "يمكنك إظهارها مرة أخرى من الزر بالأعلى." : "بعد طلب مساعدة ستظهر الحالة والاقتراح المنظم والأدوات المسموحة هنا."}</p></div> : <div className="mt-5 grid gap-4 lg:grid-cols-2">{visibleRuns.map((run) => <RunCard key={run.id} onHide={hideRun} run={run} />)}</div>}</section></div></main>;
}
