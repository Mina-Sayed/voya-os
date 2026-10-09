type RpcResponse = Readonly<{ data: unknown; error: unknown }>;
type RpcClient = Readonly<{
  rpc: (name: string, parameters: Record<string, unknown>) => PromiseLike<RpcResponse>;
}>;
type LeasedEvent = Readonly<{ id: string; attempts: number }>;
type ProviderFailure = Readonly<{ outcome: "retry" | "dead_letter" | "needs_review" | "completed"; retryAfterSeconds?: number }>;
type MarkNeedsReview = (client: RpcClient, eventId: string, workerId: string, errorCode: string) => Promise<boolean>;

export async function failWhatsappAiOutboxEvent(
  client: RpcClient,
  event: LeasedEvent,
  workerId: string,
  errorCode: string,
  maxAttempts: number,
  retryAfterSeconds: number,
  markNeedsReview: MarkNeedsReview,
): Promise<"retry" | "failed" | "needs_review"> {
  const { data, error } = await client.rpc("fail_whatsapp_ai_outbox_event_v1", {
    p_event_id: event.id,
    p_worker_id: workerId,
    p_error_code: errorCode,
    p_retry_after_seconds: retryAfterSeconds,
    p_max_attempts: maxAttempts,
  });
  if (error || (data !== "retry_wait" && data !== "dead_letter")) {
    await markNeedsReview(client, event.id, workerId, "whatsapp_ai_retry_record_failed");
    return "needs_review";
  }
  return data === "dead_letter" ? "failed" : "retry";
}

export async function failOutboxDeliveryEvent(
  client: RpcClient,
  event: LeasedEvent,
  workerId: string,
  errorCode: string,
  failure: ProviderFailure,
  maxAttempts: number,
): Promise<RpcResponse> {
  return await client.rpc("fail_outbox_delivery_event_v1", {
    p_event_id: event.id,
    p_worker_id: workerId,
    p_error_code: errorCode,
    p_retry_after_seconds: failure.retryAfterSeconds ?? 1,
    p_max_attempts: failure.outcome === "dead_letter" ? Math.max(1, event.attempts) : maxAttempts,
  });
}
