"use client";

import { useActionState } from "react";
import { Bot, CheckCircle2, CircleAlert, Clock3, LockKeyhole, Play, ShieldCheck, Wrench } from "lucide-react";
import type { AgentDefinition } from "@/domain/ai/agent-registry";
import { useCommandForm } from "@/features/shared/use-command-form";

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

function RunCard({ run }: Readonly<{ run: AiRunItem }>) {
  return <article className="rounded-[1.35rem] border border-line bg-surface p-5"><div className="flex flex-wrap items-start justify-between gap-3"><div><p className="text-[10px] font-bold text-tide">{agentLabel[run.agentKind] ?? run.agentKind} · {run.agentVersion}</p><h3 className="mt-2 text-sm font-extrabold text-harbor">{run.purpose}</h3></div><RunStatus status={run.status} /></div><div className="mt-4 grid gap-2 border-t border-line pt-3 text-[11px] text-muted sm:grid-cols-3"><span>النموذج: <bdi dir="ltr" className="font-mono text-ink">{run.modelName}</bdi></span><span>الأدوات: <bdi dir="ltr" className="font-mono text-ink">{run.toolCalls.length}</bdi></span><time dateTime={run.createdAt}>{new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium", timeStyle: "short" }).format(new Date(run.createdAt))}</time></div>{run.resultSummary ? <div className="mt-4 rounded-xl border border-[#dbe7e0] bg-[#f6faf7] p-3"><p className="text-[10px] font-bold text-tide">اقتراح قابل للمراجعة · {run.resultSummary.provider}</p><p className="mt-2 whitespace-pre-wrap text-xs leading-6 text-ink">{run.resultSummary.output}</p></div> : null}{run.toolCalls.length > 0 ? <div className="mt-4 space-y-2 border-t border-line pt-3">{run.toolCalls.map((tool) => <div className="flex items-center justify-between gap-3 rounded-xl bg-[#f6faf7] px-3 py-2 text-[11px]" key={tool.id}><span className="inline-flex min-w-0 items-center gap-2 text-harbor"><Wrench aria-hidden="true" className="size-3.5 shrink-0 text-tide" /><bdi dir="ltr" className="truncate font-mono">{tool.toolName}</bdi></span><span className={`shrink-0 font-bold ${tool.policyDecision === "allowed" ? "text-tide" : "text-coral"}`}>{tool.policyDecision === "allowed" ? "مسموح" : "مرفوض"}</span></div>)}</div> : null}</article>;
}

export function AgentCenterPage({
  agents,
  runs,
  requestRun,
}: Readonly<{ agents: readonly AgentDefinition[]; runs: readonly AiRunItem[]; requestRun: AiAction }>) {
  return <main className="min-h-[calc(100vh-74px)] bg-canvas px-4 py-6 text-ink sm:px-7 sm:py-8 lg:px-9 lg:py-10"><div className="mx-auto max-w-[1180px]"><header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9"><div className="flex flex-wrap items-start justify-between gap-5"><div className="flex gap-4"><div className="grid size-12 shrink-0 place-items-center rounded-2xl bg-harbor text-sea-glass"><Bot aria-hidden="true" className="size-6" /></div><div><p className="text-[11px] font-bold tracking-[0.08em] text-tide">مساعدة محكومة</p><h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">مركز الذكاء</h1><p className="mt-3 max-w-2xl text-sm leading-7 text-muted">راقب تعريفات الوكلاء وطلبات التشغيل وأدواتها المسموحة. هذه المرحلة لا تستدعي provider ولا تنفذ حجوزات أو مالية.</p></div></div><div className="flex items-center gap-2 rounded-xl border border-[#d4dfda] bg-white/70 px-3 py-2 text-[11px] font-semibold text-tide"><ShieldCheck aria-hidden="true" className="size-4" />اقتراحات فقط</div></div><div className="mt-7 grid gap-3 border-t border-[#d4dfda] pt-5 sm:grid-cols-3"><div><p className="font-mono text-3xl font-medium text-harbor">{agents.filter((agent) => agent.mode === "preview").length}</p><p className="mt-1 text-xs text-muted">وصلات preview لدورك</p></div><div><p className="font-mono text-3xl font-medium text-tide">{runs.length}</p><p className="mt-1 text-xs text-muted">طلبات مسجلة</p></div><div><p className="font-mono text-3xl font-medium text-[#85652e]">0</p><p className="mt-1 text-xs text-muted">تنفيذ تلقائي</p></div></div></header><section aria-labelledby="agent-registry-heading" className="mt-8"><div className="flex items-end justify-between gap-4"><div><p className="text-[11px] font-bold text-tide">الحدود</p><h2 className="mt-2 text-2xl font-extrabold tracking-[-0.08em] text-harbor" id="agent-registry-heading">الوكلاء المتاحون لدورك</h2></div><span className="rounded-full bg-sea-glass px-3 py-1.5 text-[11px] font-bold text-tide">server-owned</span></div><div className="mt-5 grid gap-5 lg:grid-cols-2">{agents.map((agent) => <AgentRequestCard agent={agent} key={agent.kind} requestRun={requestRun} />)}</div></section><section aria-labelledby="run-history-heading" className="mt-10"><div className="flex items-end justify-between gap-4"><div><p className="text-[11px] font-bold text-tide">التتبع</p><h2 className="mt-2 text-2xl font-extrabold tracking-[-0.08em] text-harbor" id="run-history-heading">سجل طلبات الوكلاء</h2></div><span className="rounded-full border border-line bg-surface px-3 py-1.5 text-[11px] font-bold text-muted">لا توجد بيانات مصطنعة</span></div>{runs.length === 0 ? <div className="mt-5 rounded-[1.6rem] border border-dashed border-[#bfd1cb] bg-surface px-6 py-14 text-center"><Bot aria-hidden="true" className="mx-auto size-7 text-tide" /><h3 className="mt-4 text-lg font-extrabold text-harbor">لم تُسجل طلبات بعد</h3><p className="mx-auto mt-2 max-w-md text-sm leading-7 text-muted">بعد طلب مساعدة ستظهر الحالة والأداة والسياسة هنا. أي طلب يبقى queued حتى إضافة provider/worker معتمد.</p></div> : <div className="mt-5 grid gap-4 lg:grid-cols-2">{runs.map((run) => <RunCard key={run.id} run={run} />)}</div>}</section></div></main>;
}
