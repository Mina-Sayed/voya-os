import { defineConfig, devices } from "@playwright/test";

const authenticatedLocal = process.env.VOYA_AUTH_E2E_LOCAL === "1";
const authenticatedApplicationOrigin = process.env.VOYA_AUTH_E2E_APP_ORIGIN;
if (
  authenticatedLocal
  && authenticatedApplicationOrigin !== "http://127.0.0.1:3102"
) {
  throw new Error("Local authenticated browser tests require their dedicated loopback application origin.");
}
const applicationOrigin = authenticatedLocal
  ? authenticatedApplicationOrigin!
  : "http://127.0.0.1:3000";

export default defineConfig({
  testDir: "./e2e",
  outputDir: "output/playwright/test-results",
  timeout: 30_000,
  use: {
    baseURL: applicationOrigin,
    trace: "retain-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  webServer: {
    command: authenticatedLocal
      ? "node scripts/test-authenticated-browser.mjs --serve-next"
      : "npm run dev -- --hostname 127.0.0.1",
    url: applicationOrigin,
    reuseExistingServer: authenticatedLocal ? false : !process.env.CI,
    gracefulShutdown: authenticatedLocal
      ? { signal: "SIGTERM", timeout: 10_000 }
      : undefined,
  },
});
