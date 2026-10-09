import { describe, expect, it, vi } from "vitest";
import { failOutboxDeliveryEvent, failWhatsappAiOutboxEvent } from "./failure-terminalization";

describe("leased outbox terminal failure transitions", () => {
  it("terminalizes the WhatsApp AI run before the worker lease can be released", async () => {
    const state = { outbox: "processing", run: "running" };
    const rpc = vi.fn(async (name: string) => {
      if (name === "fail_whatsapp_ai_outbox_event_v1") {
        state.run = "failed";
        state.outbox = "dead_letter";
        return { data: "dead_letter", error: null };
      }
      if (name === "fail_outbox_event") {
        state.outbox = "dead_letter";
        return { data: "dead_letter", error: null };
      }
      if (name === "fail_whatsapp_ai_run_v1") {
        return { data: false, error: null };
      }
      return { data: null, error: null };
    });
    const markNeedsReview = vi.fn().mockResolvedValue(true);

    const outcome = await failWhatsappAiOutboxEvent(
      { rpc },
      { id: "event-a", attempts: 6 },
      "worker-a",
      "provider_failed",
      6,
      30,
      markNeedsReview,
    );

    expect(outcome).toBe("failed");
    expect(state).toEqual({ outbox: "dead_letter", run: "failed" });
    expect(rpc).toHaveBeenCalledExactlyOnceWith("fail_whatsapp_ai_outbox_event_v1", {
      p_event_id: "event-a",
      p_worker_id: "worker-a",
      p_error_code: "provider_failed",
      p_retry_after_seconds: 30,
      p_max_attempts: 6,
    });
    expect(markNeedsReview).not.toHaveBeenCalled();
  });

  it("marks delivery terminal state in the RPC that exhausts retries", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: "dead_letter", error: null });

    await failOutboxDeliveryEvent(
      { rpc },
      { id: "event-message", attempts: 6 },
      "worker-b",
      "provider_failed",
      { outcome: "retry", retryAfterSeconds: 12 },
      6,
    );

    expect(rpc).toHaveBeenCalledExactlyOnceWith("fail_outbox_delivery_event_v1", {
      p_event_id: "event-message",
      p_worker_id: "worker-b",
      p_error_code: "provider_failed",
      p_retry_after_seconds: 12,
      p_max_attempts: 6,
    });
  });

  it("preserves retryable message delivery state before the attempt limit", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: "retry_wait", error: null });

    await failOutboxDeliveryEvent(
      { rpc },
      { id: "event-message", attempts: 5 },
      "worker-b",
      "rate_limited",
      { outcome: "retry", retryAfterSeconds: 45 },
      6,
    );

    expect(rpc.mock.calls[0]).toEqual(["fail_outbox_delivery_event_v1", {
      p_event_id: "event-message",
      p_worker_id: "worker-b",
      p_error_code: "rate_limited",
      p_retry_after_seconds: 45,
      p_max_attempts: 6,
    }]);
  });
});
