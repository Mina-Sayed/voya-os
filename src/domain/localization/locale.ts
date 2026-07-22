export type SupportedLocale = "ar" | "en";
export type TextDirection = "rtl" | "ltr";
export type ResolvedLocale = Readonly<{ locale: SupportedLocale; direction: TextDirection }>;
export function resolveLocale(value: string | null | undefined): ResolvedLocale { return value === "en" ? { locale: "en", direction: "ltr" } : { locale: "ar", direction: "rtl" }; }
