import { describe, expect, it } from "vitest";
import { stayDemoModeEnabled } from "./stay-demo-mode";

describe("stay demo content gate", () => {
  it("requires an explicit flag outside production", () => {
    expect(stayDemoModeEnabled({ NODE_ENV: "development", VOYA_STAY_DEMO_MODE: "1" })).toBe(true);
    expect(stayDemoModeEnabled({ NODE_ENV: "development" })).toBe(false);
  });

  it("never enables illustrative catalog cards in production", () => {
    expect(stayDemoModeEnabled({ NODE_ENV: "production", VOYA_STAY_DEMO_MODE: "1" })).toBe(false);
  });
});
