export type OperationalFailure = Readonly<{
  operation: string;
  requestId: string;
  code: string;
  outcome: "unavailable" | "denied" | "failed";
  cause?: unknown;
}>;

export function reportOperationalError(input: OperationalFailure): void {
  console.error(JSON.stringify({
    level: "error",
    event: "operational_failure",
    operation: input.operation,
    request_id: input.requestId,
    code: input.code,
    outcome: input.outcome,
  }));
}
