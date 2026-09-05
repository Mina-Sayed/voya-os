type LocalDateTimeParts = Readonly<{
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
  millisecond: number;
}>;

const ISO_DATE_TIME_PATTERN = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?(Z|[+-]\d{2}:\d{2})?$/u;

function utcMillisFromParts(parts: LocalDateTimeParts): number {
  const date = new Date(0);
  date.setUTCFullYear(parts.year, parts.month - 1, parts.day);
  date.setUTCHours(parts.hour, parts.minute, parts.second, parts.millisecond);
  return date.getTime();
}

function parseLocalDateTimeParts(match: RegExpExecArray): LocalDateTimeParts | null {
  const [, yearText, monthText, dayText, hourText, minuteText, secondText = "0", fractionText = ""] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const millisecond = Number(fractionText.padEnd(3, "0"));
  const monthEnd = new Date(0);
  monthEnd.setUTCFullYear(year, month, 0);
  monthEnd.setUTCHours(0, 0, 0, 0);
  const daysInMonth = monthEnd.getUTCDate();
  if (
    month < 1 || month > 12
    || day < 1 || day > daysInMonth
    || hour > 23
    || minute > 59
    || second > 59
  ) return null;
  return { year, month, day, hour, minute, second, millisecond };
}

function createTimeZoneFormatter(timeZone: string): Intl.DateTimeFormat | null {
  try {
    return new Intl.DateTimeFormat("en-US", {
      calendar: "gregory",
      day: "2-digit",
      hour: "2-digit",
      hourCycle: "h23",
      minute: "2-digit",
      month: "2-digit",
      numberingSystem: "latn",
      second: "2-digit",
      timeZone,
      year: "numeric",
    });
  } catch {
    return null;
  }
}

function formatParts(formatter: Intl.DateTimeFormat, timestamp: number): LocalDateTimeParts | null {
  const values = new Map(formatter.formatToParts(new Date(timestamp)).map((part) => [part.type, part.value]));
  const year = Number(values.get("year"));
  const month = Number(values.get("month"));
  const day = Number(values.get("day"));
  const hour = Number(values.get("hour"));
  const minute = Number(values.get("minute"));
  const second = Number(values.get("second"));
  if (![year, month, day, hour, minute, second].every(Number.isFinite)) return null;
  return { year, month, day, hour, minute, second, millisecond: 0 };
}

function sameSecond(parts: LocalDateTimeParts, other: LocalDateTimeParts): boolean {
  return parts.year === other.year
    && parts.month === other.month
    && parts.day === other.day
    && parts.hour === other.hour
    && parts.minute === other.minute
    && parts.second === other.second;
}

function localDateTimeToIso(parts: LocalDateTimeParts, timeZone: string): string | null {
  const formatter = createTimeZoneFormatter(timeZone);
  if (!formatter) return null;

  const localAsUtc = utcMillisFromParts({ ...parts, millisecond: 0 });
  const offsets = new Set<number>();
  for (const dayOffset of [-2, -1, 0, 1, 2]) {
    const offsetProbe = localAsUtc + dayOffset * 86_400_000;
    const observed = formatParts(formatter, offsetProbe);
    if (!observed) return null;
    const observedAsUtc = utcMillisFromParts(observed);
    const offsetMinutes = Math.round((observedAsUtc - offsetProbe) / 60_000);
    offsets.add(offsetMinutes);
  }

  const matches: number[] = [];
  for (const offsetMinutes of offsets) {
    const candidate = localAsUtc - offsetMinutes * 60_000;
    const observed = formatParts(formatter, candidate);
    if (observed && sameSecond(parts, observed)) matches.push(candidate + parts.millisecond);
  }
  // A skipped or repeated DST clock value is not a unique instant; fail closed instead of guessing.
  if (matches.length !== 1) return null;

  const result = new Date(matches[0]);
  return Number.isNaN(result.getTime()) ? null : result.toISOString();
}

/** Normalize an ISO date-time, interpreting offset-free values in an explicit IANA timezone. */
export function parseIsoDateTime(value: string | null, timeZone: string): string | null {
  const normalized = value?.trim();
  const normalizedTimeZone = timeZone?.trim();
  if (!normalized || !normalizedTimeZone) return null;
  const match = ISO_DATE_TIME_PATTERN.exec(normalized);
  if (!match) return null;

  const offset = match[8];
  const parts = parseLocalDateTimeParts(match);
  if (!parts) return null;
  if (offset) {
    const parsed = new Date(normalized);
    return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
  }
  return localDateTimeToIso(parts, normalizedTimeZone);
}
