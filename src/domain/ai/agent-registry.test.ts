import { expect, test } from "vitest";
import { visibleAgentDefinitions } from "./agent-registry";

test("keeps finance visible but disabled until finance policy is approved", () => {
  const agents = visibleAgentDefinitions("accountant");
  expect(agents).toEqual([expect.objectContaining({ kind: "finance", mode: "disabled" })]);
});

test("does not expose manager or finance assistants to a sales membership", () => {
  expect(visibleAgentDefinitions("sales_agent").map((agent) => agent.kind)).toEqual(["sales", "booking"]);
});
