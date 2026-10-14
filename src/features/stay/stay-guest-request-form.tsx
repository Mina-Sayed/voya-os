"use client";

import { CircleAlert, LoaderCircle, Send } from "lucide-react";
import { useId, useRef, useState, type FormEvent } from "react";
import styles from "./stay-search-pages.module.css";

type Receipt = Readonly<{ status: "received"; message: string }>;

export function StayGuestRequestForm({
  slug,
  initialCheckIn = "",
  initialCheckOut = "",
  initialGuests = 1,
  privacyNoticeUrl,
  privacyNoticeVersion,
}: Readonly<{
  slug: string;
  initialCheckIn?: string;
  initialCheckOut?: string;
  initialGuests?: number;
  privacyNoticeUrl: string;
  privacyNoticeVersion: string;
}>) {
  const consentId = useId();
  const formRef = useRef<HTMLFormElement>(null);
  const phoneRef = useRef<HTMLInputElement>(null);
  const consentRef = useRef<HTMLInputElement>(null);
  const [idempotencyKey, setIdempotencyKey] = useState(() => crypto.randomUUID());
  const [errorMessage, setErrorMessage] = useState("");
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [isPending, setIsPending] = useState(false);

  async function submitRequest(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrorMessage("");
    const formData = new FormData(event.currentTarget);
    const phone = String(formData.get("phone") ?? "").trim();
    const email = String(formData.get("email") ?? "").trim();
    const consent = formData.get("consent") === "true";
    if (!phone && !email) {
      setErrorMessage("اكتب رقم هاتف أو بريدًا إلكترونيًا للتواصل معك.");
      phoneRef.current?.focus();
      return;
    }
    if (!consent) {
      setErrorMessage("وافق على إشعار الخصوصية قبل إرسال الطلب.");
      consentRef.current?.focus();
      return;
    }

    const guestsRaw = String(formData.get("guests") ?? "");
    setIsPending(true);
    try {
      const response = await fetch("/api/stay/requests", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          slug,
          name: formData.get("name"),
          phone,
          email,
          check_in: formData.get("check_in"),
          check_out: formData.get("check_out"),
          guests: Number(guestsRaw),
          message: formData.get("message"),
          consent,
          idempotency_key: idempotencyKey,
          company: formData.get("company"),
        }),
      });
      const result = await response.json() as Partial<Receipt> & { message?: unknown };
      if (!response.ok || result.status !== "received" || typeof result.message !== "string") {
        if (response.status === 409) setIdempotencyKey(crypto.randomUUID());
        setErrorMessage(typeof result.message === "string" ? result.message : "تعذر إرسال طلبك الآن. حاول مرة أخرى.");
        return;
      }
      formRef.current?.reset();
      setIdempotencyKey(crypto.randomUUID());
      setReceipt({ status: "received", message: result.message });
    } catch {
      setErrorMessage("تعذر إرسال طلبك الآن. تحقق من الاتصال وحاول مرة أخرى.");
    } finally {
      setIsPending(false);
    }
  }

  if (receipt) {
    return <p aria-live="polite" className={styles.requestReceipt} role="status">{receipt.message}</p>;
  }

  return (
    <form className={styles.guestRequestForm} noValidate onSubmit={submitRequest} ref={formRef}>
      <input name="slug" type="hidden" value={slug} />
      <input name="idempotency_key" type="hidden" value={idempotencyKey} />
      <div className={styles.guestRequestGrid}>
        <label htmlFor={`${consentId}-name`}>
          الاسم الكامل
          <input autoComplete="name" disabled={isPending} id={`${consentId}-name`} maxLength={160} name="name" required />
        </label>
        <label htmlFor={`${consentId}-phone`}>
          رقم الهاتف <span>(اختياري إذا كتبت البريد)</span>
          <input autoComplete="tel" disabled={isPending} id={`${consentId}-phone`} inputMode="tel" maxLength={32} name="phone" placeholder="010 1234 5678 أو +20…" ref={phoneRef} type="tel" />
        </label>
        <label htmlFor={`${consentId}-email`}>
          البريد الإلكتروني <span>(اختياري إذا كتبت الهاتف)</span>
          <input autoComplete="email" disabled={isPending} id={`${consentId}-email`} maxLength={320} name="email" type="email" />
        </label>
        <label htmlFor={`${consentId}-check-in`}>
          تاريخ الوصول
          <input defaultValue={initialCheckIn} disabled={isPending} id={`${consentId}-check-in`} name="check_in" required type="date" />
        </label>
        <label htmlFor={`${consentId}-check-out`}>
          تاريخ المغادرة
          <input defaultValue={initialCheckOut} disabled={isPending} id={`${consentId}-check-out`} name="check_out" required type="date" />
        </label>
        <label htmlFor={`${consentId}-guests`}>
          عدد الضيوف
          <input defaultValue={initialGuests} disabled={isPending} id={`${consentId}-guests`} max="50" min="1" name="guests" required type="number" />
        </label>
        <label className={styles.guestRequestMessage} htmlFor={`${consentId}-message`}>
          رسالة للفريق <span>(اختياري)</span>
          <textarea disabled={isPending} id={`${consentId}-message`} maxLength={1000} name="message" rows={3} />
        </label>
      </div>
      <div className={styles.guestRequestConsent}>
        <input id={consentId} name="consent" ref={consentRef} type="checkbox" value="true" />
        <label htmlFor={consentId}>أوافق أن تتواصل VOYA معي بخصوص هذا الطلب وفق <a href={privacyNoticeUrl} rel="noreferrer" target="_blank">إشعار الخصوصية</a>، النسخة <bdi dir="ltr">{privacyNoticeVersion}</bdi>.</label>
      </div>
      <input aria-hidden="true" autoComplete="off" className={styles.guestRequestHoneypot} name="company" tabIndex={-1} type="text" />
      <p className={styles.guestRequestDisclosure}>هذا طلب لمراجعة الإقامة والتواريخ. لا ينشئ حجزًا ولا يضمن التوفر أو السعر.</p>
      <button className={styles.guestRequestButton} disabled={isPending} type="submit">
        {isPending ? <LoaderCircle aria-hidden="true" className="size-4 animate-spin" /> : <Send aria-hidden="true" className="size-4" />}
        إرسال طلب للمراجعة
      </button>
      {errorMessage ? <p aria-live="assertive" className={styles.guestRequestError} role="alert"><CircleAlert aria-hidden="true" className="size-4 shrink-0" />{errorMessage}</p> : null}
    </form>
  );
}
