import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";

const artifactsDirectory = resolve(process.cwd(), "artifacts/ui");

async function loadAllImages(page: import("@playwright/test").Page) {
  await page.locator("img").evaluateAll((images) => {
    images.forEach((image) => { (image as HTMLImageElement).loading = "eager"; });
  });
  await page.waitForFunction(() => Array.from(document.images).every((image) => image.complete));
  const brokenImages = await page.locator("img").evaluateAll((images) =>
    images.filter((image) => (image as HTMLImageElement).naturalWidth === 0).map((image) => image.getAttribute("src")),
  );
  expect(brokenImages).toEqual([]);
}

test("shows illustrative search examples and an accessible demo detail gallery", async ({ page }) => {
  const browserErrors: string[] = [];
  page.on("console", (message) => {
    if (message.type() === "error") browserErrors.push(message.text());
  });
  page.on("pageerror", (error) => browserErrors.push(error.message));
  mkdirSync(artifactsDirectory, { recursive: true });
  await page.setViewportSize({ width: 1440, height: 900 });
  const response = await page.goto("/stay/search");

  expect(response?.status()).toBe(200);
  await expect(page).toHaveTitle("نماذج الإقامة التوضيحية | VOYA Stay");
  await expect(page.getByRole("heading", { name: "نماذج الإقامة التوضيحية" })).toBeVisible();
  await expect(page.locator("[data-nextjs-dialog]")).toHaveCount(0);
  await page.addStyleTag({ content: "nextjs-portal { display: none; }" });

  const examples = page.getByRole("region", { name: "مساحات للإلهام البصري" });
  const cards = examples.getByRole("article");
  await expect(cards).toHaveCount(3);
  for (const card of await cards.all()) {
    const content = await card.innerText();
    expect(content).toContain("صورة توضيحية");
    expect(content).not.toMatch(/جنيه|ليلة|★|تقييم|متاح الآن/);
  }

  for (const width of [360, 390, 768, 1024, 1440]) {
    await page.setViewportSize({ width, height: width < 500 ? 844 : 900 });
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
      `search page should not overflow at ${width}px`,
    ).toBe(true);
  }
  await page.setViewportSize({ width: 1440, height: 900 });
  await loadAllImages(page);
  await page.screenshot({ path: resolve(artifactsDirectory, "stay-search-desktop-1440x900.png") });
  await page.screenshot({ path: resolve(artifactsDirectory, "stay-search-desktop-full.png"), fullPage: true });

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.getByRole("heading", { name: "نماذج الإقامة التوضيحية" })).toBeVisible();
  await loadAllImages(page);
  await page.screenshot({ path: resolve(artifactsDirectory, "stay-search-mobile-390x844.png") });
  await page.screenshot({ path: resolve(artifactsDirectory, "stay-search-mobile-full.png"), fullPage: true });

  await page.getByRole("link", { name: "عرض التفاصيل التوضيحية" }).first().click();
  await expect(page).toHaveURL(/\/stay\/property\/living-room-concept$/);
  await expect(page.getByRole("heading", { name: "مساحة معيشة مفتوحة" })).toBeVisible();
  await expect(page.getByText("هذه صفحة لتوضيح شكل تفاصيل الإقامة فقط، ولا تصف وحدة فعلية.")).toBeVisible();
  await expect(page.getByRole("button", { name: "طلب إقامة" })).toHaveCount(0);
  await loadAllImages(page);

  await page.screenshot({ path: resolve(artifactsDirectory, "stay-detail-mobile-390x844.png") });
  await page.screenshot({ path: resolve(artifactsDirectory, "stay-detail-mobile-full.png"), fullPage: true });

  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/stay/property/living-room-concept");
  await expect(page.getByRole("heading", { name: "مساحة معيشة مفتوحة" })).toBeVisible();
  await expect(page.locator("[data-nextjs-dialog]")).toHaveCount(0);
  await page.addStyleTag({ content: "nextjs-portal { display: none; }" });
  await loadAllImages(page);
  await page.screenshot({ path: resolve(artifactsDirectory, "stay-detail-desktop-1440x900.png") });
  await page.screenshot({ path: resolve(artifactsDirectory, "stay-detail-desktop-full.png"), fullPage: true });

  const gallery = page.getByRole("group", { name: "معرض الصور التوضيحية" });
  const galleryButtons = gallery.getByRole("button");
  await expect(galleryButtons).toHaveCount(3);
  await expect(galleryButtons.first()).toHaveAttribute("aria-pressed", "true");
  await galleryButtons.nth(1).click();
  await expect(galleryButtons.nth(1)).toHaveAttribute("aria-pressed", "true");
  await expect(gallery.getByRole("img")).toHaveAttribute("alt", /غرفة نوم.*ليست وحدة فعلية/);
  await galleryButtons.nth(2).focus();
  await page.keyboard.press("Space");
  await expect(galleryButtons.nth(2)).toBeFocused();
  await expect(galleryButtons.nth(2)).toHaveAttribute("aria-pressed", "true");
  await expect(gallery.getByRole("img")).toHaveAttribute("alt", /استوديو مفروش.*ليست وحدة فعلية/);
  expect(browserErrors).toEqual([]);
});

test("returns 404 for an unknown illustrative stay slug", async ({ page }) => {
  const response = await page.goto("/stay/property/not-a-demo-example");

  expect(response?.status()).toBe(404);
  await expect(page.getByRole("heading", { name: "الصفحة غير موجودة" })).toBeVisible();
});

test("submits public search criteria by GET and can render explicit local design examples", async ({ page }) => {
  await page.goto("/");
  await page.getByLabel("المدينة أو المنطقة").fill("القاهرة");
  await page.getByLabel("تاريخ الوصول").fill("2026-10-10");
  await page.getByLabel("تاريخ المغادرة").fill("2026-10-12");
  await page.getByLabel("عدد الضيوف").selectOption("2");
  await page.getByRole("button", { name: "ابحث عن إقامة" }).click();

  await expect(page).toHaveURL(/\/stay\/search\?destination=/u);
  await expect(page.getByRole("heading", { name: "مساحات للإلهام البصري" })).toBeVisible();
  expect(page.url()).toContain("2026-10-10");
  expect(page.url()).toContain("2026-10-12");
});
