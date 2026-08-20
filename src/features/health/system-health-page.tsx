import { Activity, AlertTriangle, Bot, CheckCircle2, Clock3, Database, GitBranch, MailWarning, MessageCircleWarning, RefreshCcw, ServerCog } from "lucide-react";
import type { ReleaseInfo } from "@/lib/release/version";

export type SystemHealthData = Readonly<{
  databaseStatus: "ok" | "not_ready";
  lastWorkerRunAt: string | null;
  lastWorkerStatus: "running" | "completed" | "failed" | null;
  pendingOutboxCount: number;
  oldestDueEventAt: string | null;
  deadLetterCount: number;
  emailFailureCount: number;
  whatsappFailureCount: number;
  aiFailureCount: number;
}>;

function formatDate(value: string | null) {
  return value
    ? new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
    : "لا يوجد سجل بعد";
}

const workerStatusLabel: Record<NonNullable<SystemHealthData["lastWorkerStatus"]>, string> = {
  running: "قيد التشغيل",
  completed: "اكتمل",
  failed: "فشل",
};

function MetricCard({ label, value, detail, tone = "neutral", Icon }: Readonly<{ label: string; value: string | number; detail: string; tone?: "neutral" | "warning" | "danger"; Icon: typeof Activity }>) {
  const toneClass = tone === "danger" ? "border-[#f0c9bf] bg-[#fff5f1] text-coral" : tone === "warning" ? "border-[#ead9ae] bg-[#fffaf0] text-[#85652e]" : "border-line bg-surface text-tide";
  return <article className={`rounded-[1.35rem] border p-5 ${toneClass}`}><div className="flex items-start justify-between gap-3"><div><p className="text-[11px] font-bold">{label}</p><p className="mt-3 font-mono text-3xl font-medium text-harbor">{value}</p></div><span className="grid size-10 place-items-center rounded-xl bg-white/70"><Icon aria-hidden="true" className="size-5" /></span></div><p className="mt-3 text-[11px] leading-5 text-muted">{detail}</p></article>;
}

export function SystemHealthPage({ release, health }: Readonly<{ release: ReleaseInfo; health: SystemHealthData }>) {
  const workerTone = health.lastWorkerStatus === "failed" ? "danger" : health.lastWorkerStatus === "running" ? "warning" : "neutral";
  const hasFailures = health.deadLetterCount > 0 || health.emailFailureCount > 0 || health.whatsappFailureCount > 0 || health.aiFailureCount > 0;
  return <main className="min-h-[calc(100vh-74px)] bg-canvas px-4 py-6 text-ink sm:px-7 sm:py-8 lg:px-9 lg:py-10"><div className="mx-auto max-w-[1180px]">
    <header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9">
      <div className="flex flex-wrap items-start justify-between gap-5"><div className="flex gap-4"><div className="grid size-12 shrink-0 place-items-center rounded-2xl bg-harbor text-sea-glass"><ServerCog aria-hidden="true" className="size-6" /></div><div><p className="text-[11px] font-bold tracking-[0.08em] text-tide">تشغيل ومراقبة</p><h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">صحة النظام</h1><p className="mt-3 max-w-2xl text-sm leading-7 text-muted">ملخص آمن لحالة الإصدار وقاعدة البيانات والـworker والتسليمات. لا نعرض أسرارًا أو تفاصيل provider.</p></div></div><a className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-[#bfd1cb] bg-white px-3 text-xs font-bold text-tide hover:bg-sea-glass/35" href="/workspace/health"><RefreshCcw aria-hidden="true" className="size-4" />تحديث البيانات</a></div>
      <div className="mt-7 grid gap-3 border-t border-[#d4dfda] pt-5 sm:grid-cols-3"><div><p className="text-[10px] font-bold text-tide">الإصدار</p><p className="mt-2 font-mono text-sm font-bold text-harbor" dir="ltr">{release.version}</p></div><div><p className="text-[10px] font-bold text-tide">Release SHA</p><p className="mt-2 truncate font-mono text-sm font-bold text-harbor" dir="ltr" title={release.commit}>{release.commit}</p></div><div><p className="text-[10px] font-bold text-tide">البيئة</p><p className="mt-2 text-sm font-bold text-harbor">{release.environment}</p></div></div>
    </header>

    <section aria-labelledby="health-status-heading" className="mt-8"><div className="flex items-end justify-between gap-4"><div><p className="text-[11px] font-bold text-tide">الحالة الأساسية</p><h2 className="mt-2 text-2xl font-extrabold tracking-[-0.08em] text-harbor" id="health-status-heading">حدود التشغيل</h2></div><span className={`inline-flex items-center gap-2 rounded-full px-3 py-1.5 text-[11px] font-bold ${health.databaseStatus === "ok" ? "bg-sea-glass text-tide" : "bg-[#fff0eb] text-coral"}`}>{health.databaseStatus === "ok" ? <CheckCircle2 aria-hidden="true" className="size-4" /> : <AlertTriangle aria-hidden="true" className="size-4" />}{health.databaseStatus === "ok" ? "قاعدة البيانات متاحة" : "قاعدة البيانات غير جاهزة"}</span></div><div className="mt-5 grid gap-4 sm:grid-cols-2"><MetricCard Icon={Database} label="Database Status" value={health.databaseStatus === "ok" ? "OK" : "Not ready"} detail="تمكنت صفحة الصحة من قراءة aggregate المسموح للمؤسسة." tone={health.databaseStatus === "ok" ? "neutral" : "danger"} /><MetricCard Icon={Clock3} label="Last Worker Run" value={health.lastWorkerStatus ? workerStatusLabel[health.lastWorkerStatus] : "لم يبدأ"} detail={formatDate(health.lastWorkerRunAt)} tone={workerTone} /></div></section>

    <section aria-labelledby="outbox-health-heading" className="mt-8"><div><p className="text-[11px] font-bold text-tide">التسليم</p><h2 className="mt-2 text-2xl font-extrabold tracking-[-0.08em] text-harbor" id="outbox-health-heading">Transactional Outbox</h2></div><div className="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-4"><MetricCard Icon={Activity} label="Pending Outbox" value={health.pendingOutboxCount} detail={health.oldestDueEventAt ? `أقدم due: ${formatDate(health.oldestDueEventAt)}` : "لا توجد أحداث مستحقة حاليًا."} tone={health.pendingOutboxCount > 0 ? "warning" : "neutral"} /><MetricCard Icon={AlertTriangle} label="Dead Letters" value={health.deadLetterCount} detail="أحداث توقفت بعد استنفاد سياسة المحاولة." tone={health.deadLetterCount > 0 ? "danger" : "neutral"} /><MetricCard Icon={MailWarning} label="Email Failures" value={health.emailFailureCount} detail="دعوات بريدية في dead-letter أو needs-review." tone={health.emailFailureCount > 0 ? "danger" : "neutral"} /><MetricCard Icon={MessageCircleWarning} label="WhatsApp Failures" value={health.whatsappFailureCount} detail="رسائل WhatsApp خارجية تحتاج مراجعة." tone={health.whatsappFailureCount > 0 ? "danger" : "neutral"} /></div></section>

    <section aria-labelledby="ai-health-heading" className="mt-8 grid gap-4 lg:grid-cols-[minmax(0,0.7fr)_minmax(0,1.3fr)]"><MetricCard Icon={Bot} label="AI Failures" value={health.aiFailureCount} detail="طلبات AI فشلت أو بقيت في needs-review." tone={health.aiFailureCount > 0 ? "danger" : "neutral"} /><article className={`rounded-[1.35rem] border p-5 ${hasFailures ? "border-[#ead9ae] bg-[#fffaf0]" : "border-[#cfe3d9] bg-[#f5faf7]"}`}><div className="flex items-start gap-3"><GitBranch aria-hidden="true" className={`mt-0.5 size-5 ${hasFailures ? "text-[#85652e]" : "text-tide"}`} /><div><h2 className="text-sm font-extrabold text-harbor">قراءة تشغيلية</h2><p className="mt-2 text-xs leading-6 text-muted">{hasFailures ? "توجد أحداث تحتاج مراجعة بشرية قبل إعادة الإرسال أو الإغلاق." : "لا توجد failures مسجلة في aggregate الحالي. تظل قنوات provider مقفلة افتراضيًا حتى اعتماد managed rollout."}</p></div></div></article></section>
  </div></main>;
}
