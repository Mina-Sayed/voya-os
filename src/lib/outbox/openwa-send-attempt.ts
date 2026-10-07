import type { ProviderDeliveryResult } from "./dispatch-contract";

type SendAttemptDependencies = Readonly<{
  begin: () => Promise<boolean>;
  clear: () => Promise<boolean>;
  send: () => Promise<ProviderDeliveryResult>;
}>;

const safePreSendFailures = new Set([
  "openwa_session_not_ready",
  "openwa_rate_limited",
  "openwa_request_setup_failed",
]);

const uncertain = (errorCode: string): ProviderDeliveryResult => ({ kind: "ambiguous", errorCode });

/** A reclaimed outbox lease must never repeat an OpenWA request whose outcome may be unknown. */
export async function sendOpenWaWithAttemptGuard(deps: SendAttemptDependencies): Promise<ProviderDeliveryResult> {
  try {
    if (!(await deps.begin())) return uncertain("openwa_send_attempt_unavailable");
  } catch {
    return uncertain("openwa_send_attempt_unavailable");
  }

  let result: ProviderDeliveryResult;
  try {
    result = await deps.send();
  } catch {
    return uncertain("openwa_delivery_unknown");
  }

  if (result.kind !== "retryable") return result;
  if (!result.errorCode || !safePreSendFailures.has(result.errorCode)) {
    return uncertain("openwa_send_attempt_uncertain");
  }
  try {
    return (await deps.clear()) ? result : uncertain("openwa_send_attempt_clear_failed");
  } catch {
    return uncertain("openwa_send_attempt_clear_failed");
  }
}
