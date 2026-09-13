/**
 * Timezones accepted by both the Node Intl runtime and PostgreSQL's IANA
 * timezone catalog. The database migration seeds the same explicit contract.
 * Do not accept arbitrary PostgreSQL aliases: a value must be renderable by
 * the application as well as interpretable by the database.
 */
export const SUPPORTED_TIMEZONES = [
  "UTC",
  "Africa/Cairo",
  "Africa/Casablanca",
  "Africa/Johannesburg",
  "Africa/Tripoli",
  "America/Chicago",
  "America/Los_Angeles",
  "America/New_York",
  "Asia/Amman",
  "Asia/Baghdad",
  "Asia/Beirut",
  "Asia/Dubai",
  "Asia/Kuwait",
  "Asia/Muscat",
  "Asia/Qatar",
  "Asia/Riyadh",
  "Europe/Berlin",
  "Europe/London",
  "Europe/Paris",
] as const;

export type SupportedTimezone = (typeof SUPPORTED_TIMEZONES)[number];

const timezoneContract = new Set<string>(SUPPORTED_TIMEZONES);

export function isSupportedTimezone(value: string | null | undefined): value is SupportedTimezone {
  return value !== null && value !== undefined && timezoneContract.has(value.trim());
}
