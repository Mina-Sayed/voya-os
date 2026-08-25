const integerPattern = /^-?\d+$/u;
const majorPattern = /^(\d+)(?:\.(\d+))?$/u;

export function currencyFractionDigits(currency: string): number {
  if (!/^[A-Z]{3}$/u.test(currency)) throw new Error("Invalid currency code");
  try {
    return new Intl.NumberFormat("en", { style: "currency", currency }).resolvedOptions().maximumFractionDigits;
  } catch {
    throw new Error("Invalid currency code");
  }
}

export function parseMajorToMinor(value: string, currency: string): string {
  const normalized = value.trim();
  const match = majorPattern.exec(normalized);
  if (!match) throw new Error("Invalid money amount");
  const digits = currencyFractionDigits(currency);
  const fraction = match[2] ?? "";
  if (fraction.length > digits) throw new Error("Too many fractional digits");
  const factor = 10n ** BigInt(digits);
  const minor = BigInt(match[1]) * factor + BigInt((fraction.padEnd(digits, "0") || "0"));
  if (minor > 9223372036854775807n) throw new Error("Money amount out of range");
  return minor.toString();
}

export function minorUnitsToMajor(value: string, currency: string): string {
  if (!integerPattern.test(value)) throw new Error("Invalid minor-unit amount");
  const digits = currencyFractionDigits(currency);
  const negative = value.startsWith("-");
  const absolute = BigInt(negative ? value.slice(1) : value);
  if (digits === 0) return `${negative ? "-" : ""}${absolute.toString()}`;
  const factor = 10n ** BigInt(digits);
  const whole = absolute / factor;
  const fraction = (absolute % factor).toString().padStart(digits, "0").replace(/0+$/u, "");
  return `${negative ? "-" : ""}${whole.toString()}${fraction ? `.${fraction}` : ""}`;
}

export function formatMinorUnits(value: string, currency: string, locale = "ar-EG"): string {
  if (!integerPattern.test(value)) throw new Error("Invalid minor-unit amount");
  const major = minorUnitsToMajor(value, currency);
  const negative = major.startsWith("-");
  const unsigned = negative ? major.slice(1) : major;
  const [whole, fraction = ""] = unsigned.split(".");
  const grouped = new Intl.NumberFormat(locale, { maximumFractionDigits: 0 }).format(BigInt(whole));
  if (!fraction) return `${negative ? "−" : ""}${grouped}`;
  const decimal = new Intl.NumberFormat(locale).formatToParts(1.1).find((part) => part.type === "decimal")?.value ?? ".";
  const localizedFraction = new Intl.NumberFormat(locale, { useGrouping: false, minimumIntegerDigits: fraction.length }).format(BigInt(fraction));
  return `${negative ? "−" : ""}${grouped}${decimal}${localizedFraction}`;
}
