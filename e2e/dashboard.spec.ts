import { expect, test } from "@playwright/test";

test("routes the public entry point to protected sign-in instead of exposing fixture operations", async ({ page }) => {
  const response = await page.goto("/");

  expect(response?.headers()["x-content-type-options"]).toBe("nosniff");
  expect(response?.headers()["x-frame-options"]).toBe("DENY");
  expect(response?.headers()["referrer-policy"]).toBe("strict-origin-when-cross-origin");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();
  await expect(page.getByText("بيانات تجريبية للعرض فقط")).toHaveCount(0);
});

test("keeps the redesigned sign-in surface usable on mobile without horizontal overflow", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/sign-in");

  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();
  await expect(page.getByLabel("البريد الإلكتروني").first()).toBeVisible();
  await expect(page.getByRole("textbox", { name: "كلمة المرور", exact: true })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("keeps workspace routes protected from the public entry point", async ({ page }) => {
  await page.goto("/workspace/properties");

  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();
});

test("renders an Arabic not-found page without echoing the requested path", async ({ page }) => {
  const response = await page.goto("/path-that-does-not-exist");

  expect(response?.status()).toBe(404);
  await expect(page.getByRole("heading", { name: "الصفحة غير موجودة" })).toBeVisible();
  await expect(page.getByRole("link", { name: "العودة إلى لوحة العمليات" })).toHaveAttribute("href", "/workspace");
  expect(await page.locator("body").innerText()).not.toContain("path-that-does-not-exist");
});
