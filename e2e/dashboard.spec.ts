import { expect, test } from "@playwright/test";

test("shows the Arabic operations dashboard at mobile and desktop widths", async ({ page }) => {
  const response = await page.goto("/");

  expect(response?.headers()["x-content-type-options"]).toBe("nosniff");
  expect(response?.headers()["x-frame-options"]).toBe("DENY");
  expect(response?.headers()["referrer-policy"]).toBe("strict-origin-when-cross-origin");

  await expect(page.getByRole("heading", { name: "صباحك منظّم" })).toBeVisible();
  await expect(page.getByText("بيانات تجريبية للعرض فقط")).toBeVisible();

  await page.setViewportSize({ width: 360, height: 800 });
  await expect(page.getByRole("heading", { name: "صباحك منظّم" })).toBeVisible();
  await expect(page.getByRole("list", { name: "إقامات الأيام القادمة" })).toBeVisible();
});
