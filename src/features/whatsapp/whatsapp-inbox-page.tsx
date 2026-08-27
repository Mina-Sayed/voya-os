"use client";

import { useActionState } from "react";
import Image from "next/image";
import { CheckCircle2, Image as ImageIcon, MessageCircle, MessageSquareText, Plus, Send, ShieldCheck, UserRound, UserRoundCog } from "lucide-react";
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
  aiEnabled?: boolean;
  conversationType?: "unknown" | "owner_onboarding" | "client_sales" | "existing_customer";
  leadId?: string | null;
  clientId?: string | null;
  propertyOwnerId?: string | null;
  propertyId?: string | null;
  aiStateVersion?: number;
  structuredState?: unknown;
  recentMessages?: readonly WhatsAppConversationMessageItem[];
}>;

export type WhatsAppConversationMessageItem = Readonly<{
  id: string;
  direction: "inbound" | "outbound";
  message_type: "text" | "image";
  body_text: string;
  caption: string | null;
  delivery_status?: string;
  media_status?: string;
  media_storage_bucket?: string | null;
  media_storage_path?: string | null;
  media_mime_hint?: string | null;
  media_byte_size?: number | null;
  created_at?: string;
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

type StateRecord = Record<string, unknown>;

function record(value: unknown): StateRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as StateRecord : {};
}

function textValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function numberValue(value: unknown): string {
  return typeof value === "number" && Number.isFinite(value) ? String(value) : "";
}

function boolValue(value: unknown): boolean {
  return value === true;
}

function money(value: unknown, currency: unknown): string | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const label = typeof currency === "string" && currency ? currency : "";
  return `${new Intl.NumberFormat("ar-EG", { maximumFractionDigits: 2 }).format(value)}${label ? ` ${label}` : ""}`;
}

function conversationTypeLabel(type: WhatsAppConversationItem["conversationType"]): string {
  if (type === "owner_onboarding") return "مالك عقار";
  if (type === "client_sales") return "عميل";
  if (type === "existing_customer") return "عميل حالي";
  return "غير معروف";
}

function missingFieldLabel(value: unknown): string {
  const labels: Record<string, string> = {
    "conversationType": "نوع المحادثة",
    "owner.displayName": "اسم المالك",
    "property.location": "الموقع",
    "property.bedrooms": "غرف النوم",
    "property.bathrooms": "الحمامات",
    "property.furnished": "حالة الفرش",
    "property.rentalType": "نوع الإيجار",
    "property.price": "السعر",
    "property.availability": "التوفر",
    "property.photos": "صور العقار",
    "lead.requestedArea": "المنطقة المطلوبة",
    "lead.dates": "تواريخ الإقامة",
    "lead.bedrooms": "غرف النوم",
    "lead.guests": "عدد الضيوف",
    "lead.budgetText": "الميزانية",
  };
  return typeof value === "string" ? labels[value] ?? value : "بيانات ناقصة";
}

function DraftSummary({ conversation }: Readonly<{ conversation: WhatsAppConversationItem }>) {
  const state = record(conversation.structuredState);
  const owner = record(state.owner);
  const property = record(state.property);
  const lead = record(state.lead);
  const missing = Array.isArray(state.missingFields) ? state.missingFields.slice(0, 6) : [];
  const type = conversation.conversationType ?? "unknown";
  const location = [textValue(property.city), textValue(property.district)].filter(Boolean).join(" / ");
  const propertyPrice = money(property.monthlyPrice, property.currency) ?? money(property.dailyPrice, property.currency) ?? money(property.weeklyPrice, property.currency);
  const leadDates = textValue(lead.checkIn) && textValue(lead.checkOut) ? `${textValue(lead.checkIn)} → ${textValue(lead.checkOut)}` : null;
  const propertyBedrooms = typeof property.bedrooms === "number" ? String(property.bedrooms) : null;
  const propertyBathrooms = typeof property.bathrooms === "number" ? String(property.bathrooms) : null;
  const leadBedrooms = typeof lead.bedrooms === "number" ? String(lead.bedrooms) : null;
  const leadGuests = typeof lead.guests === "number" ? String(lead.guests) : null;
  const images = (conversation.recentMessages ?? []).filter((message) => message.message_type === "image" && message.media_status === "stored").length;

  return (
    <section aria-label="المسودة المنظمة" className="rounded-2xl border border-[#d4dfda] bg-[#f8fbf9] p-4">
      <div className="flex items-center justify-between gap-3">
        <div><p className="text-[10px] font-bold tracking-[0.08em] text-tide">بيانات VOYA</p><h3 className="mt-1 text-sm font-extrabold text-harbor">{conversationTypeLabel(type)}</h3></div>
        {conversation.aiEnabled === false ? <span className="rounded-full bg-[#fff1ed] px-2.5 py-1 text-[10px] font-bold text-[#9f493c]">Human</span> : <span className="rounded-full bg-sea-glass px-2.5 py-1 text-[10px] font-bold text-tide">AI نشط</span>}
      </div>
      {type === "owner_onboarding" ? <div className="mt-4 space-y-1.5 text-xs leading-6 text-ink">
        <p className="font-bold text-harbor">{textValue(owner.displayName) || "اسم المالك غير معروف"}</p>
        {location ? <p>{location}</p> : null}
        {propertyBedrooms !== null || propertyBathrooms !== null ? <p>{propertyBedrooms ?? "—"} غرف · {propertyBathrooms ?? "—"} حمام</p> : null}
        {property.furnished !== null && property.furnished !== undefined ? <p>{property.furnished ? "مفروشة" : "غير مفروشة"}</p> : null}
        {propertyPrice ? <p className="font-bold text-tide">{propertyPrice}</p> : null}
        <p className="inline-flex items-center gap-1.5 text-muted"><ImageIcon aria-hidden="true" className="size-3.5" />{images} صور محفوظة</p>
      </div> : type === "client_sales" ? <div className="mt-4 space-y-1.5 text-xs leading-6 text-ink">
        <p className="font-bold text-harbor">{textValue(lead.name) || conversation.contactLabel}</p>
        {textValue(lead.requestedArea) ? <p>{textValue(lead.requestedArea)}</p> : null}
        {leadDates ? <p><bdi dir="ltr">{leadDates}</bdi></p> : null}
        {leadBedrooms !== null || leadGuests !== null ? <p>{leadBedrooms ?? "—"} غرف · {leadGuests ?? "—"} ضيوف</p> : null}
        {textValue(lead.budgetText) ? <p className="font-bold text-tide">{textValue(lead.budgetText)}</p> : null}
        {conversation.leadId ? <a className="inline-flex font-bold text-tide underline" href={`/workspace/leads#${conversation.leadId}`}>فتح الطلب في CRM</a> : null}
      </div> : <p className="mt-4 text-xs leading-6 text-muted">ستظهر البيانات المنظمة بعد فهم نية جهة الاتصال.</p>}
      {missing.length > 0 ? <div className="mt-4 border-t border-[#d4dfda] pt-3"><p className="text-[10px] font-bold text-[#85652e]">بيانات ناقصة</p><div className="mt-2 flex flex-wrap gap-1.5">{missing.map((item) => <span className="rounded-full bg-[#fff8e8] px-2 py-1 text-[10px] font-semibold text-[#85652e]" key={String(item)}>{missingFieldLabel(item)}</span>)}</div></div> : null}
    </section>
  );
}

function ConversationMessages({ conversation }: Readonly<{ conversation: WhatsAppConversationItem }>) {
  const messages = conversation.recentMessages ?? [];
  if (messages.length === 0) return <p className="rounded-xl border border-dashed border-line bg-[#fbfaf7] px-3 py-4 text-xs text-muted">لا توجد رسائل تفصيلية متاحة بعد.</p>;
  return <div aria-label="محادثة واتساب" className="max-h-72 space-y-2 overflow-y-auto rounded-2xl border border-line bg-[#fbfaf7] p-3">{messages.map((message) => <div className={`flex ${message.direction === "outbound" ? "justify-start" : "justify-end"}`} key={message.id}><div className={`max-w-[88%] rounded-2xl px-3 py-2 text-xs leading-6 ${message.direction === "outbound" ? "bg-sea-glass/60 text-harbor" : "bg-white text-ink shadow-sm"}`}>
    {message.message_type === "image" ? <div><p className="inline-flex items-center gap-1.5 font-bold text-tide"><ImageIcon aria-hidden="true" className="size-3.5" />صورة مرفقة</p>{message.caption ? <p className="mt-1">{message.caption}</p> : null}{message.media_status === "stored" ? <a className="mt-2 block overflow-hidden rounded-xl" href={`/api/workspace/whatsapp/media/${message.id}`}><Image alt="صورة من المحادثة" className="h-auto w-full object-cover" height={120} src={`/api/workspace/whatsapp/media/${message.id}`} unoptimized width={180} /></a> : <p className="mt-1 text-[10px] text-muted">جاري حفظ الصورة الخاصة…</p>}</div> : message.body_text}
  </div></div>)}</div>;
}

function ToggleAiControl({ conversation, toggleAi }: Readonly<{ conversation: WhatsAppConversationItem; toggleAi: WhatsAppAction }>) {
  const [state, action] = useActionState(toggleAi, initialActionState);
  const { formRef } = useCommandForm(state);
  const enabled = conversation.aiEnabled !== false;
  return <form action={action} ref={formRef}><input name="conversation_id" type="hidden" value={conversation.id} /><input name="enabled" type="hidden" value={enabled ? "false" : "true"} /><button className={`inline-flex min-h-10 items-center justify-center gap-2 rounded-xl px-3 text-[11px] font-bold ${enabled ? "border border-[#e6b3a6] bg-white text-[#9f493c]" : "bg-tide text-white"}`} type="submit">{enabled ? <><UserRoundCog aria-hidden="true" className="size-3.5" />استلام المحادثة</> : <><CheckCircle2 aria-hidden="true" className="size-3.5" />إعادة إلى AI</>} </button><ActionFeedback state={state} /></form>;
}

function PropertyConfirmationForm({ conversation, confirmProperty }: Readonly<{ conversation: WhatsAppConversationItem; confirmProperty: WhatsAppAction }>) {
  const [state, action, isPending] = useActionState(confirmProperty, initialActionState);
  const { formRef, idempotencyKey } = useCommandForm(state);
  const draft = record(conversation.structuredState);
  const owner = record(draft.owner);
  const property = record(draft.property);
  const fieldClass = "mt-1 h-9 w-full rounded-lg border border-[#c9d9d3] bg-white px-2 text-[11px] text-ink outline-none focus:border-tide focus:ring-2 focus:ring-sea-glass/30 disabled:bg-canvas";
  return <form action={action} className="mt-4 rounded-2xl border border-[#bcd4ca] bg-white p-3" ref={formRef}>
    <div className="flex items-center justify-between gap-3"><p className="text-xs font-extrabold text-harbor">مراجعة وتأكيد العقار</p><span className="text-[10px] text-muted">لا يتم النشر قبل التأكيد</span></div>
    <input name="conversation_id" type="hidden" value={conversation.id} /><input name="expected_version" type="hidden" value={conversation.aiStateVersion ?? 1} /><input name="confirmation_key" type="hidden" value={idempotencyKey} />
    <div className="mt-3 grid gap-2 sm:grid-cols-2">
      <label className="text-[10px] font-bold text-harbor">اسم المالك<input className={fieldClass} defaultValue={textValue(owner.displayName)} disabled={isPending} name="owner_display_name" required /></label>
      <label className="text-[10px] font-bold text-harbor">هاتف المالك<input className={fieldClass} defaultValue={textValue(owner.phone)} disabled={isPending} name="owner_phone" /></label>
      <label className="text-[10px] font-bold text-harbor">واتساب المالك<input className={fieldClass} defaultValue={textValue(owner.whatsapp)} disabled={isPending} name="owner_whatsapp" /></label>
      <label className="text-[10px] font-bold text-harbor">بريد المالك<input className={fieldClass} defaultValue={textValue(owner.email)} disabled={isPending} name="owner_email" type="email" /></label>
      <label className="text-[10px] font-bold text-harbor">وسيلة التواصل<select className={fieldClass} defaultValue={textValue(owner.preferredContactMethod)} disabled={isPending} name="owner_preferred_contact_method"><option value="">غير محدد</option><option value="phone">هاتف</option><option value="whatsapp">واتساب</option><option value="email">بريد إلكتروني</option><option value="none">لا يوجد</option></select></label>
      <label className="text-[10px] font-bold text-harbor">رمز العقار<input className={fieldClass} disabled={isPending} name="code" required /></label>
      <label className="text-[10px] font-bold text-harbor">اسم العقار<input className={fieldClass} defaultValue="" disabled={isPending} name="name" required /></label>
      <label className="text-[10px] font-bold text-harbor">المنطقة الزمنية<input className={fieldClass} defaultValue="Africa/Cairo" disabled={isPending} name="timezone" required /></label>
      <label className="text-[10px] font-bold text-harbor">المدينة<input className={fieldClass} defaultValue={textValue(property.city)} disabled={isPending} name="city" /></label>
      <label className="text-[10px] font-bold text-harbor">العنوان<input className={fieldClass} defaultValue={textValue(property.address)} disabled={isPending} name="address" /></label>
      <label className="text-[10px] font-bold text-harbor">الحي<input className={fieldClass} defaultValue={textValue(property.district)} disabled={isPending} name="district" /></label>
      <label className="text-[10px] font-bold text-harbor">رقم الوحدة<input className={fieldClass} defaultValue={textValue(property.unitLabel)} disabled={isPending} name="unit_label" /></label>
      <label className="text-[10px] font-bold text-harbor">غرف النوم<input className={fieldClass} defaultValue={numberValue(property.bedrooms)} disabled={isPending} min="0" name="bedrooms" type="number" /></label>
      <label className="text-[10px] font-bold text-harbor">الحمامات<input className={fieldClass} defaultValue={numberValue(property.bathrooms)} disabled={isPending} min="0" name="bathrooms" type="number" /></label>
      <label className="text-[10px] font-bold text-harbor">الحد الأقصى للضيوف<input className={fieldClass} defaultValue={numberValue(property.maxGuests)} disabled={isPending} min="1" name="max_guests" type="number" /></label>
      <label className="text-[10px] font-bold text-harbor">المساحة بالمتر<input className={fieldClass} defaultValue={numberValue(property.areaSqm)} disabled={isPending} min="0.01" name="area_sqm" step="0.01" type="number" /></label>
      <label className="text-[10px] font-bold text-harbor">الطابق<input className={fieldClass} defaultValue={textValue(property.floor)} disabled={isPending} name="floor" /></label>
      <label className="text-[10px] font-bold text-harbor">الفرش<select className={fieldClass} defaultValue={typeof property.furnished === "boolean" ? String(property.furnished) : ""} disabled={isPending} name="furnished"><option value="">غير محدد</option><option value="true">مفروشة</option><option value="false">غير مفروشة</option></select></label>
      <label className="text-[10px] font-bold text-harbor">السعر اليومي<input className={fieldClass} defaultValue={numberValue(property.dailyPrice)} disabled={isPending} min="0" name="daily_price" step="0.01" type="number" /></label>
      <label className="text-[10px] font-bold text-harbor">السعر الأسبوعي<input className={fieldClass} defaultValue={numberValue(property.weeklyPrice)} disabled={isPending} min="0" name="weekly_price" step="0.01" type="number" /></label>
      <label className="text-[10px] font-bold text-harbor">السعر الشهري<input className={fieldClass} defaultValue={numberValue(property.monthlyPrice)} disabled={isPending} min="0" name="monthly_price" step="0.01" type="number" /></label>
      <label className="text-[10px] font-bold text-harbor">العملة<input className={fieldClass} defaultValue={textValue(property.currency) || "EGP"} disabled={isPending} maxLength={3} name="currency" /></label>
      <label className="text-[10px] font-bold text-harbor">أقل مدة إقامة<input className={fieldClass} defaultValue={numberValue(property.minimumStayNights)} disabled={isPending} min="1" name="minimum_stay_nights" type="number" /></label>
      <label className="text-[10px] font-bold text-harbor sm:col-span-2">المرافق<input className={fieldClass} defaultValue={Array.isArray(property.amenities) ? property.amenities.filter((item): item is string => typeof item === "string").join(", ") : ""} disabled={isPending} name="amenities" placeholder="واي فاي، تكييف" /></label>
      <label className="text-[10px] font-bold text-harbor">بداية الملكية<input className={fieldClass} disabled={isPending} name="ownership_start_date" required type="date" /></label>
      <label className="text-[10px] font-bold text-harbor">نهاية الملكية<input className={fieldClass} disabled={isPending} name="ownership_end_date" required type="date" /></label>
    </div>
    <div className="mt-3 flex flex-wrap gap-3 text-[10px] font-semibold text-muted"><label className="inline-flex items-center gap-1.5"><input defaultChecked={boolValue(property.rentDaily) || property.dailyPrice !== null && property.dailyPrice !== undefined} disabled={isPending} name="rent_daily" type="checkbox" value="true" />يومي</label><label className="inline-flex items-center gap-1.5"><input defaultChecked={boolValue(property.rentWeekly) || property.weeklyPrice !== null && property.weeklyPrice !== undefined} disabled={isPending} name="rent_weekly" type="checkbox" value="true" />أسبوعي</label><label className="inline-flex items-center gap-1.5"><input defaultChecked={boolValue(property.rentMonthly) || property.monthlyPrice !== null && property.monthlyPrice !== undefined} disabled={isPending} name="rent_monthly" type="checkbox" value="true" />شهري</label></div>
    <label className="mt-3 block text-[10px] font-bold text-harbor">ملاحظات المالك<textarea className={`${fieldClass} h-16 py-2`} defaultValue={textValue(owner.notes)} disabled={isPending} name="owner_notes" /></label>
    <label className="mt-3 block text-[10px] font-bold text-harbor">ملاحظات التشغيل<textarea className={`${fieldClass} h-16 py-2`} defaultValue={textValue(property.operationalNotes)} disabled={isPending} name="operational_notes" /></label>
    <label className="mt-3 block text-[10px] font-bold text-harbor">الوصف التسويقي<textarea className={`${fieldClass} h-16 py-2`} defaultValue={textValue(property.marketingDescription)} disabled={isPending} name="marketing_description" /></label>
    <button className="mt-3 inline-flex min-h-10 w-full items-center justify-center gap-2 rounded-xl bg-harbor px-3 text-[11px] font-bold text-white disabled:opacity-50" disabled={isPending} type="submit"><CheckCircle2 aria-hidden="true" className="size-3.5" />مراجعة وتأكيد المالك والعقار</button>
    <ActionFeedback state={state} />
  </form>;
}

function ConversationCard({
  conversation,
  sendMessage,
  addNote,
  toggleAi,
  confirmProperty,
}: Readonly<{
  conversation: WhatsAppConversationItem;
  sendMessage: WhatsAppAction;
  addNote: WhatsAppAction;
  toggleAi?: WhatsAppAction;
  confirmProperty?: WhatsAppAction;
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
              <span className="mt-2 inline-flex rounded-full bg-white px-2.5 py-1 text-[10px] font-bold text-tide">{conversationTypeLabel(conversation.conversationType ?? "unknown")}</span>
            </div>
          </div>
          <span className={`shrink-0 rounded-full px-2.5 py-1 text-[10px] font-bold ${conversation.status === "closed" ? "bg-[#f1f0ed] text-muted" : "bg-sea-glass text-tide"}`}>
            {conversation.status === "handoff" ? "تسليم بشري" : conversation.status === "pending" ? "في الانتظار" : conversation.status === "closed" ? "مغلقة" : "مفتوحة"}
          </span>
        </div>
        {conversation.lastMessagePreview ? <p className="mt-5 rounded-xl border border-[#dbe7e0] bg-white/80 px-3 py-2.5 text-xs leading-6 text-ink">{conversation.lastMessagePreview}</p> : <p className="mt-5 text-xs text-muted">لا توجد رسالة مسجلة بعد.</p>}
      </div>

      <div className="grid gap-5 p-5 sm:p-6 lg:grid-cols-[1fr_0.82fr]">
        <div className="space-y-4">
          <ConversationMessages conversation={conversation} />
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

        <div className="space-y-4">
          <DraftSummary conversation={conversation} />
          {toggleAi ? <ToggleAiControl conversation={conversation} toggleAi={toggleAi} /> : null}
          {conversation.conversationType === "owner_onboarding" && confirmProperty ? <PropertyConfirmationForm confirmProperty={confirmProperty} conversation={conversation} /> : null}
        </div>
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
  toggleAi,
  confirmProperty,
}: Readonly<{
  channels: readonly WhatsAppChannelItem[];
  conversations: readonly WhatsAppConversationItem[];
  canManageChannels: boolean;
  createChannel: WhatsAppAction;
  sendMessage: WhatsAppAction;
  addNote: WhatsAppAction;
  toggleAi?: WhatsAppAction;
  confirmProperty?: WhatsAppAction;
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
          {conversations.length === 0 ? <div className="mt-5 rounded-[1.6rem] border border-dashed border-[#bfd1cb] bg-surface px-6 py-14 text-center"><MessageSquareText aria-hidden="true" className="mx-auto size-7 text-tide" /><h3 className="mt-4 text-lg font-extrabold text-harbor">لا توجد محادثات في نطاقك</h3><p className="mx-auto mt-2 max-w-md text-sm leading-7 text-muted">عند وصول حدث موثّق إلى قناة نشطة ستظهر المحادثة هنا. لا توجد بيانات تجريبية معروضة كأنها حقيقية.</p></div> : <div className="mt-5 grid gap-5 xl:grid-cols-2">{conversations.map((conversation) => <ConversationCard addNote={addNote} confirmProperty={confirmProperty} conversation={conversation} key={conversation.id} sendMessage={sendMessage} toggleAi={toggleAi} />)}</div>}
        </section>
      </div>
    </main>
  );
}
