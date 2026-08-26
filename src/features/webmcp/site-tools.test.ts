import { describe, expect, it, vi } from "vitest";
import { registerVoyaSiteTools, type WebMCPModelContext } from "./site-tools";

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

  it("forwards tool calls to the authenticated same-origin WebMCP endpoint", async () => {
    const tools = new Map<string, { execute: (input: Record<string, unknown>) => Promise<unknown> }>();
    const modelContext: WebMCPModelContext = {
      registerTool: vi.fn(async (tool) => {
        tools.set(tool.name, tool);
      }),
    };
    const invoke = vi.fn(async () => ({ ok: true }));

    await registerVoyaSiteTools(modelContext, invoke, new AbortController().signal);
    await tools.get("voya_check_property_availability")?.execute({
      propertyId: "11111111-1111-4111-8111-111111111111",
      checkIn: "2026-09-01",
      checkOut: "2026-09-05",
    });

    expect(invoke).toHaveBeenCalledWith("check_property_availability", {
      propertyId: "11111111-1111-4111-8111-111111111111",
      checkIn: "2026-09-01",
      checkOut: "2026-09-05",
    });
  });
});
