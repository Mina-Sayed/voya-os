import { expect, test } from "@playwright/test";

test("keeps unauthenticated users out of the workspace and provides a neutral access-pending page", async ({ page }) => {
  await page.goto("/workspace");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();

  await page.goto("/workspace/property-owners");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();

  await page.goto("/workspace/properties");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();

  await page.goto("/workspace/clients");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();

  await page.goto("/workspace/leads");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();

  await page.goto("/workspace/bookings");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();

  await page.goto("/workspace/availability");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();

  await page.goto("/workspace/activity");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();

  await page.goto("/workspace/approvals");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();

  await page.goto("/workspace/notifications");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "مرحبًا بعودتك" })).toBeVisible();

  await page.goto("/access-pending");
  await expect(page.getByRole("heading", { name: "لا توجد مساحة عمل متاحة الآن" })).toBeVisible();
  await expect(page.getByText("لا نعرض تفاصيل المؤسسات أو العضويات هنا.")).toBeVisible();
});
