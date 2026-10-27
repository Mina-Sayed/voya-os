"use client";

import { CalendarDays, MapPin, Search, UsersRound } from "lucide-react";
import { useRef, useState, type FormEvent } from "react";
import styles from "./stay-home-page.module.css";

type SearchField = "destination" | "arrival" | "departure" | "guests";

const errorCopy: Record<SearchField, string> = {
  destination: "أدخل المدينة أو المنطقة.",
  arrival: "اختر تاريخ الوصول.",
  departure: "اختر تاريخ المغادرة.",
  guests: "اختر عدد الضيوف.",
};

const guestOptions = ["١", "٢", "٣", "٤", "٥", "٦", "٧", "٨"] as const;

export function StaySearchForm() {
  const destinationRef = useRef<HTMLInputElement>(null);
  const arrivalRef = useRef<HTMLInputElement>(null);
  const departureRef = useRef<HTMLInputElement>(null);
  const guestsRef = useRef<HTMLSelectElement>(null);
  const [arrivalValue, setArrivalValue] = useState("");
  const [departureValue, setDepartureValue] = useState("");
  const [error, setError] = useState<{ field: SearchField; message: string } | null>(null);

  function submitSearch(event: FormEvent<HTMLFormElement>) {
    const values = new FormData(event.currentTarget);
    const destination = String(values.get("destination") ?? "").trim();
    const arrival = String(values.get("check_in") ?? "");
    const departure = String(values.get("check_out") ?? "");
    const guests = String(values.get("guests") ?? "");

    const invalidField: SearchField | null = !destination
      ? "destination"
      : !arrival
        ? "arrival"
        : !departure
          ? "departure"
          : arrival >= departure
            ? "departure"
            : !guests
              ? "guests"
              : null;

    if (invalidField) {
      event.preventDefault();
      setError({
        field: invalidField,
        message: invalidField === "departure" && arrival && departure && arrival >= departure
          ? "اختر تاريخ مغادرة بعد تاريخ الوصول."
          : errorCopy[invalidField],
      });
      if (invalidField === "destination") destinationRef.current?.focus();
      if (invalidField === "arrival") arrivalRef.current?.focus();
      if (invalidField === "departure") departureRef.current?.focus();
      if (invalidField === "guests") guestsRef.current?.focus();
      return;
    }

    setError(null);
  }

  function clearFeedback(field?: SearchField) {
    if (!field || error?.field === field) setError(null);
  }

  return (
    <form action="/stay/search" className={styles.searchPanel} method="get" noValidate onSubmit={submitSearch}>
      <div className={styles.searchGrid}>
        <div className={styles.field}>
          <label className={styles.fieldLabel} htmlFor="stay-destination">
            <MapPin aria-hidden="true" className={styles.fieldLabelIcon} />
            المدينة أو المنطقة
          </label>
          <input
            autoComplete="address-level2"
            className={styles.fieldControl}
            id="stay-destination"
            name="destination"
            onChange={() => clearFeedback("destination")}
            ref={destinationRef}
            aria-describedby={error?.field === "destination" ? "stay-destination-error" : undefined}
            aria-invalid={error?.field === "destination" || undefined}
            placeholder="اكتب وجهتك"
            required
            type="text"
          />
          {error?.field === "destination" ? <span className={styles.fieldError} id="stay-destination-error" role="alert">{error.message}</span> : null}
        </div>

        <div className={styles.field}>
          <label className={styles.fieldLabel} htmlFor="stay-arrival">
            <CalendarDays aria-hidden="true" className={styles.fieldLabelIcon} />
            تاريخ الوصول
          </label>
          <span className={styles.dateFieldWrap}>
            <input
              aria-describedby={error?.field === "arrival" ? "stay-arrival-error" : undefined}
              aria-invalid={error?.field === "arrival" || undefined}
              className={`${styles.fieldControl} ${styles.dateControl} ${arrivalValue ? "" : styles.dateControlEmpty}`}
              id="stay-arrival"
              lang="ar-EG"
              name="check_in"
              onChange={(event) => {
                setArrivalValue(event.target.value);
                clearFeedback("arrival");
              }}
              ref={arrivalRef}
              required
              type="date"
              value={arrivalValue}
            />
            {!arrivalValue ? <span aria-hidden="true" className={styles.dateHint}>اختر التاريخ</span> : null}
          </span>
          {error?.field === "arrival" ? <span className={styles.fieldError} id="stay-arrival-error" role="alert">{error.message}</span> : null}
        </div>

        <div className={styles.field}>
          <label className={styles.fieldLabel} htmlFor="stay-departure">
            <CalendarDays aria-hidden="true" className={styles.fieldLabelIcon} />
            تاريخ المغادرة
          </label>
          <span className={styles.dateFieldWrap}>
            <input
              aria-describedby={error?.field === "departure" ? "stay-departure-error" : undefined}
              aria-invalid={error?.field === "departure" || undefined}
              className={`${styles.fieldControl} ${styles.dateControl} ${departureValue ? "" : styles.dateControlEmpty}`}
              id="stay-departure"
              lang="ar-EG"
              name="check_out"
              onChange={(event) => {
                setDepartureValue(event.target.value);
                clearFeedback("departure");
              }}
              ref={departureRef}
              required
              type="date"
              value={departureValue}
            />
            {!departureValue ? <span aria-hidden="true" className={styles.dateHint}>اختر التاريخ</span> : null}
          </span>
          {error?.field === "departure" ? <span className={styles.fieldError} id="stay-departure-error" role="alert">{error.message}</span> : null}
        </div>

        <div className={`${styles.field} ${styles.guestField}`}>
          <label className={styles.fieldLabel} htmlFor="stay-guests">
            <UsersRound aria-hidden="true" className={styles.fieldLabelIcon} />
            عدد الضيوف
          </label>
          <select
            aria-describedby={error?.field === "guests" ? "stay-guests-error" : undefined}
            aria-invalid={error?.field === "guests" || undefined}
            className={styles.fieldControl}
            defaultValue=""
            id="stay-guests"
            name="guests"
            onChange={() => clearFeedback("guests")}
            ref={guestsRef}
            required
          >
            <option disabled value="">اختر العدد</option>
            {guestOptions.map((localizedCount, index) => (
              <option key={localizedCount} value={index + 1}>
                {localizedCount} {index === 0 ? "ضيف" : "ضيوف"}
              </option>
            ))}
          </select>
          {error?.field === "guests" ? <span className={styles.fieldError} id="stay-guests-error" role="alert">{error.message}</span> : null}
        </div>

        <button className={styles.searchButton} type="submit">
          <Search aria-hidden="true" className={styles.searchIcon} />
          ابحث عن إقامة
        </button>
      </div>

      <p className={styles.demoNote}>التوفر المعروض إرشادي؛ إرسال طلب إقامة لا يؤكد الحجز أو يحجز التواريخ.</p>
    </form>
  );
}
