import type { StaySearchCriteria } from "@/lib/stay/public-catalog";

function isIsoCalendarDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(value)) return false;
  const timestamp = Date.parse(`${value}T00:00:00.000Z`);
  return Number.isFinite(timestamp) && new Date(timestamp).toISOString().slice(0, 10) === value;
}

function optionalBoundedInteger(value: string | null, minimum: number, maximum: number): number | null | "invalid" {
  if (value === null || value.trim() === "") return null;
  const normalized = value.trim();
  if (!/^\d+$/u.test(normalized)) return "invalid";
  const parsed = Number(normalized);
  return Number.isSafeInteger(parsed) && parsed >= minimum && parsed <= maximum ? parsed : "invalid";
}

export function parseStaySearchCriteria(searchParams: URLSearchParams): StaySearchCriteria | null {
  const rawDestination = searchParams.get("destination")?.trim() ?? "";
  if (rawDestination.length > 100) return null;
  const destination = rawDestination || null;
  const rawCheckIn = searchParams.get("check_in")?.trim() ?? "";
  const rawCheckOut = searchParams.get("check_out")?.trim() ?? "";
  if ((rawCheckIn === "") !== (rawCheckOut === "")) return null;
  if (rawCheckIn && (!isIsoCalendarDate(rawCheckIn) || !isIsoCalendarDate(rawCheckOut) || rawCheckIn >= rawCheckOut)) return null;
  const guests = optionalBoundedInteger(searchParams.get("guests"), 1, 50);
  const bedrooms = optionalBoundedInteger(searchParams.get("bedrooms"), 0, 100);
  if (guests === "invalid" || bedrooms === "invalid") return null;
  return {
    destination,
    checkIn: rawCheckIn || null,
    checkOut: rawCheckOut || null,
    guests,
    bedrooms,
  };
}
