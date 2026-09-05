const BIGINT_MAX = BigInt("9223372036854775807");
const BIGINT_RADIX = BigInt("10");

const ZERO_DECIMAL_CURRENCIES = new Set([
  "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF",
  "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF",
]);

const THREE_DECIMAL_CURRENCIES = new Set(["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]);

function isCurrencyCode(value: string): boolean {
  return /^[A-Z]{3}$/u.test(value.trim());
}

/** ISO 4217 uses two fraction digits by default; exceptional 0/3-digit codes are explicit. */
export function currencyMinorDigits(currency: string): number {
  const normalized = currency.trim();
  if (THREE_DECIMAL_CURRENCIES.has(normalized)) return 3;
  if (ZERO_DECIMAL_CURRENCIES.has(normalized)) return 0;
  return 2;
}

function parseMinorInteger(value: string, currency: string): bigint | null {
  const normalizedCurrency = currency.trim();
  const normalizedValue = value.trim();
  if (!isCurrencyCode(normalizedCurrency) || !/^\d+$/u.test(normalizedValue)) return null;
  try {
    const amount = BigInt(normalizedValue);
    return amount <= BIGINT_MAX ? amount : null;
  } catch {
    return null;
  }
}

/** Convert a user-entered major-unit decimal string to the exact stored minor-unit integer. */
export function parseMajorAmountToMinor(value: string, currency: string): string | null {
  const normalizedCurrency = currency.trim();
  const normalizedValue = value.trim();
  if (!isCurrencyCode(normalizedCurrency) || !/^(?:0|[1-9]\d*)(?:\.\d+)?$/u.test(normalizedValue)) return null;

  const [whole, fraction = ""] = normalizedValue.split(".");
  const digits = currencyMinorDigits(normalizedCurrency);
  if (fraction.length > digits) return null;

  try {
    const amount = BigInt(`${whole}${fraction.padEnd(digits, "0")}`);
    return amount <= BIGINT_MAX ? amount.toString() : null;
  } catch {
    return null;
  }
}

/** Format a stored minor-unit integer for a human-facing amount without Number precision loss. */
export function formatMinorAmount(value: string, currency: string, locale = "ar-EG"): string | null {
  const amount = parseMinorInteger(value, currency);
  if (amount === null) return null;

  const digits = currencyMinorDigits(currency.trim());
  const factor = BIGINT_RADIX ** BigInt(digits);
  const whole = amount / factor;
  const fraction = amount % factor;
  const integer = new Intl.NumberFormat(locale, { maximumFractionDigits: 0 }).format(whole);
  if (digits === 0) return integer;

  const decimal = new Intl.NumberFormat(locale).formatToParts(1.1).find((part) => part.type === "decimal")?.value ?? ".";
  const fractional = new Intl.NumberFormat(locale, {
    useGrouping: false,
    minimumIntegerDigits: digits,
    maximumFractionDigits: 0,
  }).format(Number(fraction));
  return `${integer}${decimal}${fractional}`;
}

/** Return a plain decimal string suitable for an HTML input value. */
export function formatMinorAmountForInput(value: string, currency: string): string | null {
  const amount = parseMinorInteger(value, currency);
  if (amount === null) return null;

  const digits = currencyMinorDigits(currency.trim());
  const factor = BIGINT_RADIX ** BigInt(digits);
  const whole = amount / factor;
  if (digits === 0) return whole.toString();
  return `${whole.toString()}.${(amount % factor).toString().padStart(digits, "0")}`;
}
