export type WhatsappPropertyConfirmationFields = Readonly<{
  ownerDisplayName: string;
  ownerPhone: string | null;
  ownerWhatsapp: string | null;
  ownerEmail: string | null;
  ownerPreferredContactMethod: "phone" | "whatsapp" | "email" | "none" | null;
  ownerNotes: string | null;
  propertyCode: string;
  propertyName: string;
  timezone: string;
  address: string | null;
  city: string | null;
  unitLabel: string | null;
  bedrooms: number | null;
  maxGuests: number | null;
  operationalNotes: string | null;
  bathrooms: number | null;
  areaSqm: number | null;
  floor: string | null;
  furnished: boolean | null;
  district: string | null;
  rentDaily: boolean;
  rentWeekly: boolean;
  rentMonthly: boolean;
  dailyPrice: number | null;
  weeklyPrice: number | null;
  monthlyPrice: number | null;
  currency: string | null;
  amenities: readonly string[];
  minimumStayNights: number | null;
  marketingDescription: string | null;
  ownershipStartDate: string;
  ownershipEndDate: string;
}>;

export type WhatsappPropertyConfirmationResult =
  | Readonly<{ ok: true; value: WhatsappPropertyConfirmationFields }>
  | Readonly<{ ok: false; errors: readonly string[] }>;

function text(formData: FormData, key: string): string | null {
  const value = formData.get(key);
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function optionalText(formData: FormData, key: string, maximum: number, errors: string[]): string | null {
  const value = text(formData, key);
  if (value !== null && value.length > maximum) errors.push(`${key}_too_long`);
  return value?.slice(0, maximum) ?? null;
}

function requiredText(formData: FormData, key: string, maximum: number, errors: string[]): string {
  const value = text(formData, key);
  if (!value) errors.push(`${key}_required`);
  else if (value.length > maximum) errors.push(`${key}_too_long`);
  return value?.slice(0, maximum) ?? "";
}

function optionalNumber(formData: FormData, key: string, minimum: number, maximum: number, errors: string[]): number | null {
  const value = text(formData, key);
  if (value === null) return null;
  if (!/^(?:\d+)(?:\.\d{1,2})?$/u.test(value)) {
    errors.push(`${key}_invalid`);
    return null;
  }
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < minimum || parsed > maximum) errors.push(`${key}_invalid`);
  return Number.isFinite(parsed) && parsed >= minimum && parsed <= maximum ? parsed : null;
}

function optionalInteger(formData: FormData, key: string, minimum: number, maximum: number, errors: string[]): number | null {
  const value = text(formData, key);
  if (value === null) return null;
  if (!/^\d+$/u.test(value)) {
    errors.push(`${key}_invalid`);
    return null;
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) errors.push(`${key}_invalid`);
  return Number.isSafeInteger(parsed) && parsed >= minimum && parsed <= maximum ? parsed : null;
}

function optionalBoolean(formData: FormData, key: string, errors: string[]): boolean | null {
  const value = text(formData, key);
  if (value === null) return null;
  if (value !== "true" && value !== "false") {
    errors.push(`${key}_invalid`);
    return null;
  }
  return value === "true";
}

function date(formData: FormData, key: string, errors: string[]): string {
  const value = text(formData, key);
  if (!value || !/^\d{4}-\d{2}-\d{2}$/u.test(value)) errors.push(`${key}_invalid`);
  return value ?? "";
}

export function parseWhatsappPropertyConfirmation(formData: FormData): WhatsappPropertyConfirmationResult {
  const errors: string[] = [];
  const ownerPreferred = text(formData, "owner_preferred_contact_method");
  if (ownerPreferred !== null && !["phone", "whatsapp", "email", "none"].includes(ownerPreferred)) errors.push("owner_preferred_contact_method_invalid");
  const currency = optionalText(formData, "currency", 3, errors);
  if (currency !== null && !/^[A-Z]{3}$/u.test(currency)) errors.push("currency_invalid");
  const start = date(formData, "ownership_start_date", errors);
  const end = date(formData, "ownership_end_date", errors);
  if (start && end && start >= end) errors.push("ownership_range_invalid");
  const amenities = optionalText(formData, "amenities", 4_000, errors)
    ?.split(",")
    .map((item) => item.trim())
    .filter(Boolean)
    .slice(0, 50) ?? [];
  const value: WhatsappPropertyConfirmationFields = {
    ownerDisplayName: requiredText(formData, "owner_display_name", 160, errors),
    ownerPhone: optionalText(formData, "owner_phone", 320, errors),
    ownerWhatsapp: optionalText(formData, "owner_whatsapp", 320, errors),
    ownerEmail: optionalText(formData, "owner_email", 320, errors),
    ownerPreferredContactMethod: ownerPreferred === "phone" || ownerPreferred === "whatsapp" || ownerPreferred === "email" || ownerPreferred === "none" ? ownerPreferred : null,
    ownerNotes: optionalText(formData, "owner_notes", 2_000, errors),
    propertyCode: requiredText(formData, "code", 80, errors),
    propertyName: requiredText(formData, "name", 160, errors),
    timezone: requiredText(formData, "timezone", 80, errors),
    address: optionalText(formData, "address", 320, errors),
    city: optionalText(formData, "city", 160, errors),
    unitLabel: optionalText(formData, "unit_label", 80, errors),
    bedrooms: optionalInteger(formData, "bedrooms", 0, 100, errors),
    maxGuests: optionalInteger(formData, "max_guests", 1, 1000, errors),
    operationalNotes: optionalText(formData, "operational_notes", 2_000, errors),
    bathrooms: optionalInteger(formData, "bathrooms", 0, 100, errors),
    areaSqm: optionalNumber(formData, "area_sqm", 0.01, 100_000, errors),
    floor: optionalText(formData, "floor", 80, errors),
    furnished: optionalBoolean(formData, "furnished", errors),
    district: optionalText(formData, "district", 160, errors),
    rentDaily: text(formData, "rent_daily") === "true",
    rentWeekly: text(formData, "rent_weekly") === "true",
    rentMonthly: text(formData, "rent_monthly") === "true",
    dailyPrice: optionalNumber(formData, "daily_price", 0, 1_000_000_000, errors),
    weeklyPrice: optionalNumber(formData, "weekly_price", 0, 1_000_000_000, errors),
    monthlyPrice: optionalNumber(formData, "monthly_price", 0, 1_000_000_000, errors),
    currency,
    amenities,
    minimumStayNights: optionalInteger(formData, "minimum_stay_nights", 1, 3650, errors),
    marketingDescription: optionalText(formData, "marketing_description", 4_000, errors),
    ownershipStartDate: start,
    ownershipEndDate: end,
  };
  return errors.length > 0 ? { ok: false, errors: [...new Set(errors)] } : { ok: true, value };
}
