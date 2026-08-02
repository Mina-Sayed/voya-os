const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/u;

export function normalizeEmailAddress(value: string): string {
  return value.trim().toLowerCase();
}

export function isValidEmailAddress(value: string): boolean {
  return emailPattern.test(normalizeEmailAddress(value));
}
