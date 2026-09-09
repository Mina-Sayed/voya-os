/**
 * Currencies supported by the current Voya commercial boundary.
 *
 * The database migration with the same contract is the final authority for
 * persisted values. Keep this list in sync when the product explicitly adds a
 * currency; unknown ISO-looking codes must not receive a guessed scale.
 */
export const SUPPORTED_CURRENCIES = [
  { code: "AED", minorDigits: 2, label: "AED — درهم إماراتي" },
  { code: "BHD", minorDigits: 3, label: "BHD — دينار بحريني" },
  { code: "EGP", minorDigits: 2, label: "EGP — جنيه مصري" },
  { code: "EUR", minorDigits: 2, label: "EUR — يورو" },
  { code: "GBP", minorDigits: 2, label: "GBP — جنيه إسترليني" },
  { code: "IQD", minorDigits: 3, label: "IQD — دينار عراقي" },
  { code: "JOD", minorDigits: 3, label: "JOD — دينار أردني" },
  { code: "JPY", minorDigits: 0, label: "JPY — ين ياباني" },
  { code: "KWD", minorDigits: 3, label: "KWD — دينار كويتي" },
  { code: "LYD", minorDigits: 3, label: "LYD — دينار ليبي" },
  { code: "MAD", minorDigits: 2, label: "MAD — درهم مغربي" },
  { code: "OMR", minorDigits: 3, label: "OMR — ريال عُماني" },
  { code: "QAR", minorDigits: 2, label: "QAR — ريال قطري" },
  { code: "SAR", minorDigits: 2, label: "SAR — ريال سعودي" },
  { code: "TND", minorDigits: 3, label: "TND — دينار تونسي" },
  { code: "USD", minorDigits: 2, label: "USD — دولار أمريكي" },
] as const;

export type SupportedCurrencyCode = (typeof SUPPORTED_CURRENCIES)[number]["code"];

const currencyContract = new Map<string, (typeof SUPPORTED_CURRENCIES)[number]>(SUPPORTED_CURRENCIES.map((currency) => [currency.code, currency]));

export function getCurrencyContract(value: string | null | undefined) {
  const normalized = value?.trim();
  return normalized ? currencyContract.get(normalized) ?? null : null;
}

export function isSupportedCurrency(value: string | null | undefined): value is SupportedCurrencyCode {
  return getCurrencyContract(value) !== null;
}

export function currencyMinorDigits(value: string | null | undefined): number | null {
  return getCurrencyContract(value)?.minorDigits ?? null;
}
