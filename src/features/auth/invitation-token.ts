const INVITATION_TOKEN_PATTERN = /^[0-9a-f]{64}$/u;

export function isValidInvitationToken(value: unknown): value is string {
  return typeof value === "string" && INVITATION_TOKEN_PATTERN.test(value);
}

export function invitationPath(token: string): string {
  return `/invite?token=${encodeURIComponent(token)}`;
}
