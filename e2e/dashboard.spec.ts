import { expect, test } from "@playwright/test";

test("redirects the public entry point to the protected sign-in screen", async ({ page }) => {
  const response = await page.goto("/");

  expect(response?.headers()["x-content-type-options"]).toBe("nosniff");
  expect(response?.headers()["x-frame-options"]).toBe("DENY");
  expect(response?.headers()["referrer-policy"]).toBe("strict-origin-when-cross-origin");

  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بك" })).toBeVisible();
  await expect(page.getByRole("button", { name: "دخول بالبريد وكلمة المرور" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "أرسل رابط الدخول" })).toBeDisabled();
});

test("keeps the unavailable sign-in screen usable on mobile", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");

  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "كل إقامة تبدأ بدخول مضبوط." })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("routes a protected properties request through sign-in", async ({ page }) => {
  await page.goto("/workspace/properties");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بك" })).toBeVisible();
});

test("renders an Arabic not-found page without echoing the requested path", async ({ page }) => {
  const response = await page.goto("/path-that-does-not-exist");

  expect(response?.status()).toBe(404);
  await expect(page.getByRole("heading", { name: "الصفحة غير موجودة" })).toBeVisible();
  await expect(page.getByRole("link", { name: "العودة إلى لوحة العمليات" })).toHaveAttribute("href", "/");
  expect(await page.locator("body").innerText()).not.toContain("path-that-does-not-exist");
});
