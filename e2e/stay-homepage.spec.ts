import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";

const artifactsDirectory = resolve(process.cwd(), "artifacts/ui");

test("captures the responsive homepage and verifies its public GET search", async ({ page }) => {
  const browserErrors: string[] = [];
  page.on("console", (message) => {
    if (message.type() === "error") browserErrors.push(message.text());
  });
  page.on("pageerror", (error) => browserErrors.push(error.message));
  mkdirSync(artifactsDirectory, { recursive: true });

  await page.setViewportSize({ width: 1440, height: 900 });
  const response = await page.goto("/");

  expect(response?.status()).toBe(200);
  await expect(page).toHaveTitle("VOYA Stay | إقامات مفروشة بطلب مراجعة واضح");
  await expect(page.getByRole("heading", { name: "إقامتك المفروشة تبدأ من هنا" })).toBeVisible();
  await expect(page.getByText("إقامات منشورة بمراجعة VOYA")).toBeVisible();
  await expect(page.getByText("صورة توضيحية — ليست وحدة فعلية")).toBeVisible();
  await expect(page.getByRole("navigation", { name: "التنقل الرئيسي" })).toBeVisible();
  const accommodationSection = page.getByRole("region", { name: "استكشف الإقامات المنشورة" });
  await expect(accommodationSection.getByRole("article")).toHaveCount(3);
  await expect(accommodationSection.getByText("صورة توضيحية").first()).toBeVisible();
  await expect(page.getByRole("link", { name: "استكشف الإقامات" })).toHaveAttribute("href", "/stay/search");
  for (const card of await accommodationSection.getByRole("article").all()) {
    expect(await card.innerText()).not.toMatch(/جنيه|ليلة|★|تقييم/);
  }
  await expect(page.getByRole("region", { name: "خدمات الرحلة" }).getByRole("article")).toHaveCount(2);
  await expect(page.getByRole("region", { name: "كيف تعمل VOYA Stay" }).getByRole("listitem")).toHaveCount(3);
  await expect(page.getByRole("region", { name: "وضوح ومساندة" })).toContainText("ولا يستقبل الموقع طلبات حتى تفعيلها");
  await expect(page.locator("[data-nextjs-dialog]")).toHaveCount(0);
  await page.addStyleTag({ content: "nextjs-portal { display: none; }" });
  await page.screenshot({ path: resolve(artifactsDirectory, "homepage-desktop-1440x900.png") });
  await page.screenshot({ path: resolve(artifactsDirectory, "homepage-desktop-full.png"), fullPage: true });
  await page.getByRole("navigation", { name: "التنقل الرئيسي" }).getByRole("link", { name: "الإقامات" }).click();
  await expect(page).toHaveURL(/#featured$/);
  await page.evaluate(() => {
    window.history.replaceState({}, "", "/");
    window.scrollTo(0, 0);
  });

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.getByRole("heading", { name: "إقامتك المفروشة تبدأ من هنا" })).toBeVisible();
  await page.screenshot({ path: resolve(artifactsDirectory, "homepage-mobile-390x844.png") });
  await page.screenshot({ path: resolve(artifactsDirectory, "homepage-mobile-full.png"), fullPage: true });

  for (const width of [360, 390, 768, 1024, 1440]) {
    await page.setViewportSize({ width, height: width === 360 ? 800 : width === 390 ? 844 : 900 });
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
      `document should not overflow at ${width}px`,
    ).toBe(true);
  }

  await page.setViewportSize({ width: 390, height: 844 });
  await page.reload();
  await page.keyboard.press("Tab");
  await expect(page.getByRole("link", { name: "تجاوز إلى المحتوى" })).toBeFocused();
  await page.getByRole("banner").getByRole("link", { name: "ابدأ البحث", exact: true }).click();
  await expect(page).toHaveURL(/#stay-search$/);

  const destination = page.getByRole("textbox", { name: "المدينة أو المنطقة" });
  const arrival = page.getByLabel("تاريخ الوصول");
  const departure = page.getByLabel("تاريخ المغادرة");
  const guests = page.getByLabel("عدد الضيوف");

  await page.getByRole("button", { name: "ابحث عن إقامة" }).click();
  await expect(page.getByText("أدخل المدينة أو المنطقة.", { exact: true })).toBeVisible();
  await expect(destination).toBeFocused();

  await destination.fill("القاهرة");
  await arrival.fill("2026-10-10");
  await departure.fill("2026-10-12");
  await guests.focus();
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  await expect(guests).toHaveValue("2");
  await page.getByRole("button", { name: "ابحث عن إقامة" }).click();
  await expect(page).toHaveURL(/\/stay\/search\?destination=.*check_in=2026-10-10/u);
  await expect(page.getByRole("heading", { name: "مساحات للإلهام البصري" })).toBeVisible();

  await page.locator("summary[aria-label='فتح قائمة الموقع']").click();
  await expect(page.getByRole("navigation", { name: "التنقل على الهاتف" })).toBeVisible();
  await page.getByRole("navigation", { name: "التنقل على الهاتف" }).getByRole("link", { name: "كيف تعمل" }).click();
  await expect(page).toHaveURL(/#how-it-works$/);
  expect(browserErrors).toEqual([]);
});
