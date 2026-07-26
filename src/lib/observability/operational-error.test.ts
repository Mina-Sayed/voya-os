import { afterEach, describe, expect, it, vi } from "vitest";
import { reportOperationalError } from "./operational-error";

afterEach(() => vi.restoreAllMocks());

describe("reportOperationalError", () => {
  it("emits only explicitly safe operational fields", () => {
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    reportOperationalError({
      operation: "workspace.memberships",
      requestId: "11111111-1111-4111-8111-111111111111",
      code: "membership_query_failed",
      outcome: "unavailable",
      cause: new Error("token=secret customer@example.com"),
    });

    expect(write).toHaveBeenCalledWith(JSON.stringify({
      level: "error",
      event: "operational_failure",
      operation: "workspace.memberships",
      request_id: "11111111-1111-4111-8111-111111111111",
      code: "membership_query_failed",
      outcome: "unavailable",
    }));
    expect(write.mock.calls.flat().join(" ")).not.toContain("secret");
    expect(write.mock.calls.flat().join(" ")).not.toContain("customer@example.com");
  });
});
