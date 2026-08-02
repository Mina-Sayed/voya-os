export function parseIsoDateTime(value: string | null): string | null {
  const normalized = value?.trim();
  if (!normalized) return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,3})?)?(?:Z|[+-]\d{2}:\d{2})?$/.exec(normalized);
  if (!match) return null;
  const [, year, month, day, hour, minute, second = "0"] = match;
  const daysInMonth = new Date(Date.UTC(Number(year), Number(month), 0)).getUTCDate();
  if (
    Number(month) < 1 || Number(month) > 12
    || Number(day) < 1 || Number(day) > daysInMonth
    || Number(hour) > 23
    || Number(minute) > 59
    || Number(second) > 59
  ) return null;
  const parsed = new Date(normalized);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
}
