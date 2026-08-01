import { expect, test } from "@playwright/test";

test("shows the Arabic sign-in screen with configured password and magic-link entry points", async ({ page }) => {
  await page.goto("/sign-in");

  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();
  await expect(page.getByRole("button", { name: "دخول بالبريد وكلمة المرور" })).toBeEnabled();
  await expect(page.getByLabel("كلمة المرور")).toBeVisible();
  await expect(page.getByRole("button", { name: "أرسل رابط الدخول" })).toBeEnabled();

  await page.setViewportSize({ width: 360, height: 800 });
  await expect(page.getByRole("heading", { name: "كل إقامة تبدأ بدخول مضبوط." })).toBeVisible();
});
