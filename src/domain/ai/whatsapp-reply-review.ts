/**
 * Deterministic pre-send review gate for AI-authored WhatsApp replies.
 *
 * Product decision (owner, 2026-10-19): booking confirmation and sending listing
 * data (prices, availability, property assets) to a customer are strictly human
 * actions. The AI may converse and collect facts, but a reply that carries money,
 * a booking commitment, or an availability claim must never be auto-delivered —
 * it is held for a human to review and send.
 *
 * This module is intentionally framework-light and deterministic: it is a safety
 * gate, not an AI judgement. It over-approximates on purpose — a false positive
 * only means a human reviews the message, while a false negative would let the
 * agent commit money or inventory autonomously.
 */

export type WhatsappReplyReviewReason =
  | "booking_commitment"
  | "monetary_amount"
  | "availability_commitment";

export const WHATSAPP_REPLY_REVIEW_RULES_VERSION = "1";

const REVIEW_REASON_ORDER: readonly WhatsappReplyReviewReason[] = [
  "booking_commitment",
  "monetary_amount",
  "availability_commitment",
];

const BOOKING_COMMITMENT_TERMS: readonly string[] = [
  "تم حجز",
  "حجزت",
  "حجزك",
  "حجزنا",
  "تم تأكيد",
  "تم التاكيد",
  "التأكيد",
  "تأكيد الحجز",
  "تم تسجيل",
  "سجلنا",
  "سجلت",
  "نسجل",
  "محجوز",
  "محجوزة",
  "محجوز لك",
  "booked",
  "booking is confirmed",
  "booking confirmed",
  "confirmed your",
  "your booking",
  "reservation",
  "reserved",
  "we have reserved",
];

const AVAILABILITY_TERMS: readonly string[] = [
  "متاح",
  "متاحه",
  "متاحة",
  "متاحاً",
  "متوفر",
  "متوفرة",
  "فاضية",
  "فاضي",
  "فارغة",
  "فارغ",
  "خالية",
  "خالي",
  "شاغرة",
  "شاغر",
  "متبقية",
  "متبقي",
  "ما عليه حجز",
  "عليه حجز",
  "عليها حجز",
  "عليه أي حجز",
  "مفيش حجز",
  "تقدر تحجز",
  "ممكن تحجز",
  "available",
  "is available",
  "is free",
  "still free",
  "is open",
  "works for",
  "is fine for",
  "fits for",
  "vacant",
];

const CURRENCY_TERMS: readonly string[] = [
  "جنيه",
  "ج.م",
  "ريال",
  "درهم",
  "دينار",
  "قرش",
  "دولار",
  "ألف",
  "ألفان",
  "آلاف",
  "مليون",
  "egp",
  "usd",
  "sar",
  "aed",
  "l.e",
  "l.e.",
  "$",
  "€",
  "£",
];

/** Adjacent characters around a number that may carry its currency marker. */
const CURRENCY_WINDOW = 14;

function normalizeDigits(input: string): string {
  let output = "";
  for (const character of input) {
    const code = character.codePointAt(0) ?? 0;
    // Arabic-Indic (U+0660..U+0669) and Extended Arabic-Indic (U+06F0..U+06F9).
    if (code >= 0x0660 && code <= 0x0669) {
      output += String.fromCodePoint(code - 0x0660 + 0x30);
    } else if (code >= 0x06f0 && code <= 0x06f9) {
      output += String.fromCodePoint(code - 0x06f0 + 0x30);
    } else {
      output += character;
    }
  }
  return output;
}

function normalize(text: string): string {
  return normalizeDigits(text)
    .replace(/ـ/g, "")
    // Arabic diacritics and the superscript alef.
    .replace(/[ً-ٰٟ]/g, "")
    // Bidi controls plus every other invisible formatting character (zero-width
    // space/non-joiner/joiner, LRM, word joiner, soft hyphen, BOM). Without this a
    // single copied ZWSP inside "متاحة" would split the term and slip past the gate.
    .replace(/[\p{Cf}­﻿]/gu, "")
    .toLowerCase();
}

function includesTerm(haystack: string, terms: readonly string[]): boolean {
  return terms.some((term) => haystack.includes(term));
}

/**
 * Money is detected two ways, both of which can only add matches:
 * a run of three or more digits, or any currency/magnitude word anywhere in the
 * reply (so a price spelled out as "ثلاثون ألف جنيه" is caught even with no digits).
 */
function hasMonetaryAmount(normalized: string): boolean {
  if (/\d{3,}/.test(normalized)) return true;
  if (includesTerm(normalized, CURRENCY_TERMS)) return true;
  for (const match of normalized.matchAll(/\d+/g)) {
    const digits = match[0];
    if (digits.length >= 3) return true;
    const start = match.index ?? 0;
    const windowStart = Math.max(0, start - CURRENCY_WINDOW);
    const windowEnd = Math.min(normalized.length, start + digits.length + CURRENCY_WINDOW);
    if (includesTerm(normalized.slice(windowStart, windowEnd), CURRENCY_TERMS)) return true;
  }
  return false;
}

/**
 * Returns every reason the reply must not be auto-delivered, in a stable order.
 * An empty array means the reply is safe to auto-send under the existing gates.
 */
export function detectWhatsappReplyReview(
  reply: string | null | undefined,
): readonly WhatsappReplyReviewReason[] {
  if (typeof reply !== "string" || !reply.trim()) return [];
  const normalized = normalize(reply);
  if (!normalized) return [];

  const matched = new Set<WhatsappReplyReviewReason>();
  if (includesTerm(normalized, BOOKING_COMMITMENT_TERMS)) matched.add("booking_commitment");
  if (hasMonetaryAmount(normalized)) matched.add("monetary_amount");
  if (includesTerm(normalized, AVAILABILITY_TERMS)) matched.add("availability_commitment");

  return REVIEW_REASON_ORDER.filter((reason) => matched.has(reason));
}