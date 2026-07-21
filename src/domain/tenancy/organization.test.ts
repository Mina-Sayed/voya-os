import { describe, expect, test } from "vitest";
import { createOrganizationId, isOrganizationId } from "./organization";

describe("organization identity", () => {
  test("accepts a non-empty UUID-shaped organization ID", () => {
    expect(createOrganizationId("4e3f2115-660a-42f5-9816-88d5b2f4cc8c")).toBe(
      "4e3f2115-660a-42f5-9816-88d5b2f4cc8c",
    );
  });

  test("rejects an empty organization ID", () => {
    expect(() => createOrganizationId(" ")).toThrow("Organization ID is required");
    expect(isOrganizationId(" ")).toBe(false);
  });
});
