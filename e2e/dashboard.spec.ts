import { expect, test } from "@playwright/test";

test("shows honest disabled dashboard controls on desktop", async ({ page }) => {
  const response = await page.goto("/");

  expect(response?.headers()["x-content-type-options"]).toBe("nosniff");
  expect(response?.headers()["x-frame-options"]).toBe("DENY");
  expect(response?.headers()["referrer-policy"]).toBe("strict-origin-when-cross-origin");

  await expect(page.getByRole("heading", { name: "صباحك منظّم" })).toBeVisible();
  await expect(page.getByText("بيانات تجريبية للعرض فقط")).toBeVisible();
  await expect(page.getByRole("button", { name: "التنبيهات — قريبًا" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "حساب المشغّل — قريبًا" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "المزيد من خيارات الوصول — قريبًا" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "عرض قائمة القرارات — قريبًا" })).toBeDisabled();
  await expect(page.getByRole("link", { name: "الإعدادات" })).toHaveCount(0);
});

test("opens and closes the mobile navigation without horizontal overflow", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");

  await expect(page.getByRole("heading", { name: "صباحك منظّم" })).toBeVisible();
  await expect(page.getByRole("list", { name: "إقامات الأيام القادمة" })).toBeVisible();

  await page.getByRole("button", { name: "فتح التنقل" }).click();
  const mobileNavigation = page.getByRole("navigation", { name: "التنقل على الهاتف" });
  await expect(mobileNavigation).toBeVisible();
  await expect(mobileNavigation.getByRole("link", { name: "نظرة عامة" })).toHaveAttribute("href", "/");
  await expect(mobileNavigation.getByRole("link", { name: "الإقامات" })).toHaveAttribute("href", "/workspace/bookings");
  await expect(mobileNavigation.getByRole("link", { name: "العقارات" })).toHaveAttribute("href", "/workspace/properties");
  await expect(mobileNavigation.getByRole("link", { name: "العملاء" })).toHaveAttribute("href", "/workspace/clients");
  await expect(mobileNavigation.getByText("الماليات").locator("..")).toHaveAttribute("aria-disabled", "true");
  await expect(mobileNavigation.getByText("الإعدادات").locator("..")).toHaveAttribute("aria-disabled", "true");

  await page.keyboard.press("Escape");
  await expect(mobileNavigation).toHaveCount(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("routes the properties sidebar link through the protected workspace", async ({ page }) => {
  await page.goto("/");

  await page.getByRole("link", { name: "العقارات" }).click();

  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();
});

test("renders an Arabic not-found page without echoing the requested path", async ({ page }) => {
  const response = await page.goto("/path-that-does-not-exist");

  expect(response?.status()).toBe(404);
  await expect(page.getByRole("heading", { name: "الصفحة غير موجودة" })).toBeVisible();
  await expect(page.getByRole("link", { name: "العودة إلى لوحة العمليات" })).toHaveAttribute("href", "/");
  expect(await page.locator("body").innerText()).not.toContain("path-that-does-not-exist");
});
