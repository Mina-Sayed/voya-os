import { expect, test } from "vitest";
import { GET } from "./route";

test("liveness does not depend on external configuration", async () => {
  const response = GET();
  expect(response.status).toBe(200);
  await expect(response.json()).resolves.toMatchObject({ status: "ok", release_sha: expect.any(String) });
});
