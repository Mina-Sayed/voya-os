import { describe, expect, test, vi } from "vitest";
import { sendOpenWaWithAttemptGuard } from "./openwa-send-attempt";

describe("OpenWA durable send attempt", () => {
  test("never calls the provider when a prior attempt or lost lease refuses the mark", async () => {
    const send = vi.fn(async () => ({ kind: "delivered" as const, providerMessageId: "wamid-1" }));
    const clear = vi.fn(async () => true);

    await expect(sendOpenWaWithAttemptGuard({ begin: async () => false, clear, send })).resolves.toEqual({
      kind: "ambiguous", errorCode: "openwa_send_attempt_unavailable",
    });
    expect(send).not.toHaveBeenCalled();
    expect(clear).not.toHaveBeenCalled();
  });

  test.each(["openwa_session_not_ready", "openwa_rate_limited", "openwa_request_setup_failed"])(
    "clears the mark only after a known pre-send refusal: %s",
    async (errorCode) => {
      const clear = vi.fn(async () => true);
      const result = { kind: "retryable" as const, errorCode };

      await expect(sendOpenWaWithAttemptGuard({
        begin: async () => true,
        clear,
        send: async () => result,
      })).resolves.toEqual(result);
      expect(clear).toHaveBeenCalledOnce();
    },
  );

  test("keeps the mark and asks for review if clearing a safe refusal fails", async () => {
    await expect(sendOpenWaWithAttemptGuard({
      begin: async () => true,
      clear: async () => false,
      send: async () => ({ kind: "retryable", errorCode: "openwa_session_not_ready" }),
    })).resolves.toEqual({ kind: "ambiguous", errorCode: "openwa_send_attempt_clear_failed" });
  });

  test.each([
    { kind: "delivered" as const, providerMessageId: "wamid-1" },
    { kind: "ambiguous" as const, errorCode: "openwa_delivery_unknown" },
    { kind: "permanent" as const, errorCode: "openwa_rejected" },
  ])("retains the mark after a $kind result", async (result) => {
    const clear = vi.fn(async () => true);
    await expect(sendOpenWaWithAttemptGuard({ begin: async () => true, clear, send: async () => result }))
      .resolves.toEqual(result);
    expect(clear).not.toHaveBeenCalled();
  });

  test("retains the mark and asks for review after an unrecognized retryable result", async () => {
    const clear = vi.fn(async () => true);
    await expect(sendOpenWaWithAttemptGuard({
      begin: async () => true,
      clear,
      send: async () => ({ kind: "retryable", errorCode: "unexpected" }),
    })).resolves.toEqual({ kind: "ambiguous", errorCode: "openwa_send_attempt_uncertain" });
    expect(clear).not.toHaveBeenCalled();
  });
});
