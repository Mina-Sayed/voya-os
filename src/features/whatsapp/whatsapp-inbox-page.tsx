"use client";

import { useActionState } from "react";
import { MessageCircle, MessageSquareText, Plus, Send, ShieldCheck, UserRound } from "lucide-react";
import { useCommandForm } from "@/features/shared/use-command-form";

export type WhatsAppChannelItem = Readonly<{
  id: string;
  provider: string;
  externalChannelId: string;
  displayName: string;
  status: string;
  killSwitch: boolean;
  createdAt: string;
}>;

export type WhatsAppConversationItem = Readonly<{
  id: string;
  channelId: string;
  channelName: string;
  contactLabel: string;
  status: string;
  assignedMembershipId: string | null;
  lastMessageAt: string | null;
  lastMessagePreview: string | null;
  lastMessageDirection: string | null;
}>;

export type WhatsAppActionState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
}>;

export type WhatsAppAction = (
  previousState: WhatsAppActionState,
  formData: FormData,
) => Promise<WhatsAppActionState>;

const initialActionState: WhatsAppActionState = { status: "idle", message: "" };

function formatDate(value: string | null) {
  if (!value) return "لم تصل رسالة بعد";
  return new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
}

function ActionFeedback({ state }: Readonly<{ state: WhatsAppActionState }>) {
  if (state.status === "idle" || !state.message) return null;
  const tone = state.status === "success" ? "text-tide" : state.status === "denied" ? "text-coral" : "text-[#85652e]";
  return <p aria-live="polite" className={`mt-2 text-[11px] font-semibold ${tone}`}>{state.message}</p>;
}

function ConversationCard({
  conversation,
  sendMessage,
  addNote,
}: Readonly<{
  conversation: WhatsAppConversationItem;
  sendMessage: WhatsAppAction;
  addNote: WhatsAppAction;
}>) {
  const [sendState, sendAction] = useActionState(sendMessage, initialActionState);
  const [noteState, noteAction] = useActionState(addNote, initialActionState);
  const { formRef: sendFormRef, idempotencyKey: sendIdempotencyKey } = useCommandForm(sendState);
  const { formRef: noteFormRef } = useCommandForm(noteState);

  return (
    <article className="overflow-hidden rounded-[1.6rem] border border-line bg-surface shadow-[0_12px_32px_rgba(16,33,38,0.04)]">
      <div className="border-b border-line bg-[#f3f8f5] p-5 sm:p-6">
        <div className="flex items-start justify-between gap-4">
          <div className="flex min-w-0 items-start gap-3">
            <div className="grid size-11 shrink-0 place-items-center rounded-2xl bg-harbor text-sea-glass"><UserRound aria-hidden="true" className="size-5" /></div>
            <div className="min-w-0">
              <h2 className="truncate text-base font-extrabold tracking-[-0.06em] text-harbor">{conversation.contactLabel}</h2>
              <p className="mt-1 text-[11px] text-muted">{conversation.channelName} · {formatDate(conversation.lastMessageAt)}</p>
            </div>
          </div>
          <span className={`shrink-0 rounded-full px-2.5 py-1 text-[10px] font-bold ${conversation.status === "closed" ? "bg-[#f1f0ed] text-muted" : "bg-sea-glass text-tide"}`}>
            {conversation.status === "handoff" ? "تسليم بشري" : conversation.status === "pending" ? "في الانتظار" : conversation.status === "closed" ? "مغلقة" : "مفتوحة"}
          </span>
        </div>
        {conversation.lastMessagePreview ? <p className="mt-5 rounded-xl border border-[#dbe7e0] bg-white/80 px-3 py-2.5 text-xs leading-6 text-ink">{conversation.lastMessagePreview}</p> : <p className="mt-5 text-xs text-muted">لا توجد رسالة مسجلة بعد.</p>}
      </div>

      <div className="grid gap-5 p-5 sm:p-6 lg:grid-cols-[1fr_0.74fr]">
        <form action={sendAction} className="rounded-2xl border border-line bg-white p-4" ref={sendFormRef}>
          <input name="conversation_id" type="hidden" value={conversation.id} />
          <input name="idempotency_key" type="hidden" value={sendIdempotencyKey} />
          <label className="text-xs font-bold text-harbor" htmlFor={`message-${conversation.id}`}>رد يدوي</label>
          <textarea className="mt-2 min-h-24 w-full resize-y rounded-xl border border-line bg-[#fbfaf7] px-3 py-2.5 text-xs leading-6 outline-none transition focus:border-tide focus:ring-2 focus:ring-sea-glass/50" id={`message-${conversation.id}`} name="body_text" placeholder="اكتب رد الفريق هنا…" required />
          <button className="mt-3 inline-flex min-h-11 w-full items-center justify-center gap-2 rounded-xl bg-harbor px-4 text-xs font-bold text-white transition hover:bg-[#1e574b] disabled:cursor-not-allowed disabled:opacity-50" type="submit"><Send aria-hidden="true" className="size-4" />تسجيل الرد للإرسال</button>
          <ActionFeedback state={sendState} />
        </form>

        <form action={noteAction} className="rounded-2xl border border-dashed border-[#bfd1cb] bg-[#f8fbf9] p-4" ref={noteFormRef}>
          <input name="conversation_id" type="hidden" value={conversation.id} />
          <label className="text-xs font-bold text-harbor" htmlFor={`note-${conversation.id}`}>ملاحظة داخلية</label>
          <textarea className="mt-2 min-h-24 w-full resize-y rounded-xl border border-line bg-white px-3 py-2.5 text-xs leading-6 outline-none transition focus:border-tide focus:ring-2 focus:ring-sea-glass/50" id={`note-${conversation.id}`} name="note_text" placeholder="لا تظهر للعميل…" required />
          <button className="mt-3 inline-flex min-h-11 w-full items-center justify-center gap-2 rounded-xl border border-[#bfd1cb] bg-white px-4 text-xs font-bold text-tide transition hover:bg-sea-glass/35" type="submit"><MessageSquareText aria-hidden="true" className="size-4" />حفظ الملاحظة</button>
          <ActionFeedback state={noteState} />
        </form>
      </div>
    </article>
  );
}

function ChannelSetup({ createChannel }: Readonly<{ createChannel: WhatsAppAction }>) {
  const [state, action] = useActionState(createChannel, initialActionState);
  const { formRef } = useCommandForm(state);
  return (
    <form action={action} className="mt-6 rounded-[1.6rem] border border-dashed border-[#c7d8cf] bg-[#f8fbf9] p-5 sm:p-6" ref={formRef}>
      <div className="flex items-start gap-3"><div className="grid size-10 place-items-center rounded-xl bg-sea-glass text-tide"><Plus aria-hidden="true" className="size-5" /></div><div><h2 className="text-base font-extrabold text-harbor">إضافة قناة اختبار</h2><p className="mt-1 text-xs leading-6 text-muted">تسجيل تعريف القناة فقط. لا يتم إرسال أي رسالة قبل تفعيل adapter وworker موثوقين.</p></div></div>
      <div className="mt-5 grid gap-3 sm:grid-cols-3">
        <input className="h-11 rounded-xl border border-line bg-white px-3 text-xs outline-none focus:border-tide focus:ring-2 focus:ring-sea-glass/50" name="provider" placeholder="provider مثل meta_cloud_sandbox" defaultValue="meta_cloud_sandbox" required />
        <input className="h-11 rounded-xl border border-line bg-white px-3 text-xs outline-none focus:border-tide focus:ring-2 focus:ring-sea-glass/50" name="external_channel_id" placeholder="معرّف القناة" required />
        <input className="h-11 rounded-xl border border-line bg-white px-3 text-xs outline-none focus:border-tide focus:ring-2 focus:ring-sea-glass/50" name="display_name" placeholder="اسم ظاهر للفريق" required />
      </div>
      <button className="mt-4 inline-flex min-h-11 items-center gap-2 rounded-xl bg-tide px-4 text-xs font-bold text-white hover:bg-harbor" type="submit"><Plus aria-hidden="true" className="size-4" />حفظ تعريف القناة</button>
      <ActionFeedback state={state} />
    </form>
  );
}

export function WhatsAppInboxPage({
  channels,
  conversations,
  canManageChannels,
  createChannel,
  sendMessage,
  addNote,
}: Readonly<{
  channels: readonly WhatsAppChannelItem[];
  conversations: readonly WhatsAppConversationItem[];
  canManageChannels: boolean;
  createChannel: WhatsAppAction;
  sendMessage: WhatsAppAction;
  addNote: WhatsAppAction;
}>) {
  const activeChannels = channels.filter((channel) => channel.status === "active" && !channel.killSwitch);
  return (
    <main className="min-h-[calc(100vh-74px)] bg-canvas px-4 py-6 text-ink sm:px-7 sm:py-8 lg:px-9 lg:py-10">
      <div className="mx-auto max-w-[1180px]">
        <header className="rounded-[2rem] border border-[#d4dfda] bg-[#f0f7f4] px-6 py-7 shadow-[0_18px_44px_rgba(16,33,38,0.05)] sm:px-9 sm:py-9">
          <div className="flex flex-wrap items-start justify-between gap-5">
            <div className="flex gap-4"><div className="grid size-12 shrink-0 place-items-center rounded-2xl bg-harbor text-sea-glass"><MessageCircle aria-hidden="true" className="size-6" /></div><div><p className="text-[11px] font-bold tracking-[0.08em] text-tide">تواصل بشري مضبوط</p><h1 className="mt-2 text-3xl font-bold tracking-[-0.09em] text-harbor sm:text-4xl">صندوق واتساب</h1><p className="mt-3 max-w-2xl text-sm leading-7 text-muted">تابع المحادثات، اترك ملاحظات داخلية، وسجّل ردود الفريق دون منح القناة صلاحية تنفيذية أو أتمتة غير مراقبة.</p></div></div>
            <div className="flex items-center gap-2 rounded-xl border border-[#d4dfda] bg-white/70 px-3 py-2 text-[11px] font-semibold text-tide"><ShieldCheck aria-hidden="true" className="size-4" />صلاحيات المؤسسة مطبقة</div>
          </div>
          <div className="mt-7 grid gap-3 border-t border-[#d4dfda] pt-5 sm:grid-cols-3"><div><p className="font-mono text-3xl font-medium text-harbor">{conversations.length}</p><p className="mt-1 text-xs text-muted">محادثة في نطاقك</p></div><div><p className="font-mono text-3xl font-medium text-tide">{activeChannels.length}</p><p className="mt-1 text-xs text-muted">قناة جاهزة للتسجيل</p></div><div><p className="font-mono text-3xl font-medium text-[#85652e]">{channels.length - activeChannels.length}</p><p className="mt-1 text-xs text-muted">قناة متوقفة أو محمية</p></div></div>
        </header>

        {activeChannels.length === 0 ? <section className="mt-6 rounded-[1.6rem] border border-dashed border-[#c7d8cf] bg-surface px-6 py-10 text-center"><MessageCircle aria-hidden="true" className="mx-auto size-7 text-tide" /><h2 className="mt-4 text-xl font-extrabold text-harbor">لا توجد قناة نشطة بعد</h2><p className="mx-auto mt-2 max-w-lg text-sm leading-7 text-muted">سجّل قناة sandbox من تعريفها فقط. التحقق الخارجي والإرسال الفعلي يظلان مغلقين حتى إضافة adapter وworker وسياسة provider معتمدة.</p></section> : null}
        {canManageChannels ? <ChannelSetup createChannel={createChannel} /> : null}

        <section aria-labelledby="conversation-queue-heading" className="mt-8">
          <div className="flex items-end justify-between gap-4"><div><p className="text-[11px] font-bold text-tide">قائمة العمل</p><h2 className="mt-2 text-2xl font-extrabold tracking-[-0.08em] text-harbor" id="conversation-queue-heading">المحادثات</h2></div><span className="rounded-full bg-sea-glass px-3 py-1.5 text-[11px] font-bold text-tide">الردود بشرية</span></div>
          {conversations.length === 0 ? <div className="mt-5 rounded-[1.6rem] border border-dashed border-[#bfd1cb] bg-surface px-6 py-14 text-center"><MessageSquareText aria-hidden="true" className="mx-auto size-7 text-tide" /><h3 className="mt-4 text-lg font-extrabold text-harbor">لا توجد محادثات في نطاقك</h3><p className="mx-auto mt-2 max-w-md text-sm leading-7 text-muted">عند وصول حدث موثّق إلى قناة نشطة ستظهر المحادثة هنا. لا توجد بيانات تجريبية معروضة كأنها حقيقية.</p></div> : <div className="mt-5 grid gap-5 xl:grid-cols-2">{conversations.map((conversation) => <ConversationCard addNote={addNote} conversation={conversation} key={conversation.id} sendMessage={sendMessage} />)}</div>}
        </section>
      </div>
    </main>
  );
}
