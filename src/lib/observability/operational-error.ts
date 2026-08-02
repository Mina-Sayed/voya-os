export type OperationalFailure = Readonly<{
  operation: string;
  requestId: string;
  code: string;
  outcome: "unavailable" | "denied" | "failed";
  cause?: unknown;
}>;

function safeCauseCode(cause: unknown): string | undefined {
  if (typeof cause !== "object" || cause === null || !("code" in cause)) return undefined;
  const code = (cause as { code?: unknown }).code;
  return typeof code === "string" && /^[A-Za-z0-9:_-]{1,64}$/u.test(code) ? code : undefined;
}

export function reportOperationalError(input: OperationalFailure): void {
  const causeCode = safeCauseCode(input.cause);
  console.error(JSON.stringify({
    level: "error",
    event: "operational_failure",
    operation: input.operation,
    request_id: input.requestId,
    code: input.code,
    outcome: input.outcome,
    ...(causeCode ? { cause_code: causeCode } : {}),
  }));
}
