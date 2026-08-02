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
const authenticatedWorkspaceSpec = "**/authenticated-workspace.spec.ts";
const publicWebServerCommand =
  "env NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:55321 NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_test VOYA_APP_URL=http://127.0.0.1:3000 npm run dev -- --hostname 127.0.0.1";

export default defineConfig({
  testDir: "./e2e",
  outputDir: "output/playwright/test-results",
  timeout: 30_000,
  use: {
    baseURL: applicationOrigin,
    trace: "retain-on-failure",
  },
  workers: 1,
  projects: [
    {
      name: "chromium",
      testIgnore: authenticatedLocal ? undefined : authenticatedWorkspaceSpec,
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  webServer: {
    command: authenticatedLocal
      ? "node scripts/test-authenticated-browser.mjs --serve-next"
      : publicWebServerCommand,
    url: applicationOrigin,
    reuseExistingServer: authenticatedLocal ? false : !process.env.CI,
    gracefulShutdown: authenticatedLocal
      ? { signal: "SIGTERM", timeout: 10_000 }
      : undefined,
  },
});
