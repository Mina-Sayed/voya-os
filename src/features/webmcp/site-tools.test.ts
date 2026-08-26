import { describe, expect, it, vi } from "vitest";
import { registerVoyaSiteTools, type WebMCPModelContext, type WebMCPTool } from "./site-tools";
import { invokeWebMCPTool } from "./webmcp-site-tools";

describe("registerVoyaSiteTools", () => {
  it("registers the v0.1 VOYA site-tool allowlist with correct read-only hints", async () => {
    const registered: Array<{ tool: { name: string; annotations?: { readOnlyHint?: boolean } }; signal?: AbortSignal }> = [];
    const modelContext: WebMCPModelContext = {
      registerTool: vi.fn(async (tool, options) => {
        registered.push({ tool, signal: options?.signal });
      }),
    };
    const controller = new AbortController();

    await registerVoyaSiteTools(modelContext, vi.fn(), controller.signal);

    expect(registered.map(({ tool }) => tool.name)).toEqual([
      "voya_search_properties",
      "voya_search_clients",
      "voya_check_property_availability",
      "voya_calculate_booking_quote",
      "voya_create_booking_draft",
    ]);
    expect(registered.slice(0, 4).every(({ tool }) => tool.annotations?.readOnlyHint === true)).toBe(true);
    expect(registered[4]?.tool.annotations?.readOnlyHint).toBe(false);
    expect(registered.every(({ signal }) => signal === controller.signal)).toBe(true);
  });

  it("forwards the WebMCP execution signal with tool calls", async () => {
    const tools = new Map<string, WebMCPTool>();
    const modelContext: WebMCPModelContext = {
      registerTool: vi.fn(async (tool) => {
        tools.set(tool.name, tool);
      }),
    };
    const invoke = vi.fn(async () => ({ ok: true }));
    const executionController = new AbortController();
    const input = {
      propertyId: "11111111-1111-4111-8111-111111111111",
      checkIn: "2026-09-01",
      checkOut: "2026-09-05",
    };

    await registerVoyaSiteTools(modelContext, invoke, new AbortController().signal);
    await tools.get("voya_check_property_availability")?.execute(input, { signal: executionController.signal });

    expect(invoke).toHaveBeenCalledWith("check_property_availability", input, executionController.signal);
  });

  it("aborts the booking-draft fetch when WebMCP cancels execution", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation((_input, init) => {
      return new Promise<Response>((_resolve, reject) => {
        const signal = init?.signal;
        if (!signal) {
          reject(new Error("missing abort signal"));
          return;
        }
        const rejectAbort = () => reject(new DOMException("Aborted", "AbortError"));
        if (signal.aborted) {
          rejectAbort();
          return;
        }
        signal.addEventListener("abort", rejectAbort, { once: true });
      });
    });
    const controller = new AbortController();

    try {
      const pending = invokeWebMCPTool("create_booking_draft", {
        propertyId: "11111111-1111-4111-8111-111111111111",
        clientId: "33333333-3333-4333-8333-333333333333",
        checkIn: "2026-09-01",
        checkOut: "2026-09-05",
        amountMinor: "1000000",
        currency: "EGP",
        idempotencyKey: "webmcp-cancel-test",
      }, controller.signal);

      controller.abort();

      await expect(pending).rejects.toMatchObject({ name: "AbortError" });
      expect(fetchMock).toHaveBeenCalledWith("/api/workspace/webmcp", expect.objectContaining({ signal: controller.signal }));
    } finally {
      fetchMock.mockRestore();
    }
  });
});
