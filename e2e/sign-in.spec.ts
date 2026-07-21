import { expect, test } from "@playwright/test";

test("shows the Arabic sign-in screen without enabling an unconfigured provider", async ({ page }) => {
  await page.goto("/sign-in");

  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();
  await expect(page.getByText("الدخول غير مهيأ في هذه البيئة بعد.")).toBeVisible();
  await expect(page.getByRole("button", { name: "أرسل رابط الدخول" })).toBeDisabled();

  await page.setViewportSize({ width: 360, height: 800 });
  await expect(page.getByRole("heading", { name: "كل إقامة تبدأ بدخول مضبوط." })).toBeVisible();
});
