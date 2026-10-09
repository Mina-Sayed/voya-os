const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/u;

export function normalizeEmailAddress(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

export function isValidEmailAddress(value: unknown): boolean {
  return emailPattern.test(normalizeEmailAddress(value));
}
