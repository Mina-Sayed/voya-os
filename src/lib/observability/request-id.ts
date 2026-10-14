// Canonical request correlation id shared by the edge proxy and server code.
// A client may suggest an id, but only a short token of safe characters is
// echoed; anything else falls back to a generated UUID. Validation matters:
// the value reaches response headers and structured logs, so newline or
// control characters must never pass through (header injection).
export const REQUEST_ID_HEADER = "x-request-id";

const REQUEST_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/u;

export function resolveRequestId(incoming: string | null): string {
  const candidate = incoming?.trim() ?? "";
  return REQUEST_ID_PATTERN.test(candidate) ? candidate : crypto.randomUUID();
}
