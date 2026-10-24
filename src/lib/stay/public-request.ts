import { createHmac } from "node:crypto";

export type NormalizedVoyaStayRequest = Readonly<{
  slug: string;
  name: string;
  phone: string | null;
  email: string | null;
  checkIn: string;
  checkOut: string;
  guests: number;
  message: string | null;
  consent: true;
  idempotencyKey: string;
  honeypot: string;
}>;

const slugPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/u;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" ? value.trim() : null;
}

function validDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(value)) return false;
  const timestamp = Date.parse(`${value}T00:00:00.000Z`);
  return Number.isFinite(timestamp) && new Date(timestamp).toISOString().slice(0, 10) === value;
}

function normalizeEmail(value: string | null): string | null | "invalid" {
  if (!value) return null;
  if (value.length > 320 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value)) return "invalid";
  return value.toLowerCase();
}

function normalizePhone(value: string | null): string | null | "invalid" {
  if (!value) return null;
  let normalized = value.replace(/[\s().-]/gu, "");
  if (normalized.startsWith("00")) normalized = `+${normalized.slice(2)}`;
  if (!normalized.startsWith("+")) {
    const digits = normalized.replace(/\D/gu, "");
    if (/^01[0125]\d{8}$/u.test(digits)) normalized = `+20${digits.slice(1)}`;
    else if (/^1[0125]\d{8}$/u.test(digits)) normalized = `+20${digits}`;
    else return "invalid";
  }
  if (!/^\+[1-9]\d{6,14}$/u.test(normalized)) return "invalid";
  return normalized;
}

export function validateVoyaStayRequest(value: unknown): NormalizedVoyaStayRequest | null {
  if (!isRecord(value)) return null;
  const slug = stringValue(value.slug);
  const name = stringValue(value.name);
  const rawPhone = stringValue(value.phone);
  const rawEmail = stringValue(value.email);
  const checkIn = stringValue(value.check_in);
  const checkOut = stringValue(value.check_out);
  const guestsValue = typeof value.guests === "number" ? String(value.guests) : stringValue(value.guests);
  const message = stringValue(value.message);
  const idempotencyKey = stringValue(value.idempotency_key);
  const honeypot = stringValue(value.company) ?? "";
  const consent = value.consent;

  if (!slug || !slugPattern.test(slug) || slug.length > 80
    || !name || name.length > 160
    || !checkIn || !validDate(checkIn)
    || !checkOut || !validDate(checkOut) || checkIn >= checkOut
    || !guestsValue || !/^\d+$/u.test(guestsValue)
    || !idempotencyKey || !uuidPattern.test(idempotencyKey)
    || (message !== null && message.length > 1000)
    || consent !== true
    || honeypot.length > 200) return null;

  const guests = Number(guestsValue);
  if (!Number.isSafeInteger(guests) || guests < 1 || guests > 50) return null;
  const phone = normalizePhone(rawPhone);
  const email = normalizeEmail(rawEmail);
  if (phone === "invalid" || email === "invalid" || (phone === null && email === null)) return null;

  return {
    slug, name, phone, email, checkIn, checkOut, guests,
    message: message || null, consent: true, idempotencyKey, honeypot,
  };
}

function keyedFingerprint(secret: string, domain: string, values: readonly unknown[]): string {
  if (Buffer.byteLength(secret, "utf8") < 32) throw new Error("VOYA Stay request HMAC secret is unavailable.");
  return createHmac("sha256", secret).update(`${domain}:`).update(JSON.stringify(values)).digest("hex");
}

export function hmacStayContactFingerprint(secret: string, request: NormalizedVoyaStayRequest): string {
  return keyedFingerprint(secret, "voya-stay-contact-v1", [request.phone, request.email]);
}

export function hmacStayRequestFingerprint(
  secret: string,
  request: NormalizedVoyaStayRequest,
  consentVersion: string,
): string {
  return keyedFingerprint(secret, "voya-stay-request-v1", [
    request.slug, request.name, request.phone, request.email,
    request.checkIn, request.checkOut, request.guests, request.message,
    request.consent, consentVersion,
  ]);
}
