import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { useCommandForm } from "./use-command-form";

type State = Readonly<{ status: "idle" | "success" | "retry" }>;

function Harness({ state }: Readonly<{ state: State }>) {
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form ref={formRef}><output data-testid="key">{idempotencyKey}</output></form>;
}

describe("useCommandForm", () => {
  it("keeps a key across retries and rotates it for every new success result", () => {
    const idle = { status: "idle" } as const;
    const view = render(<Harness state={idle} />);
    const initialKey = screen.getByTestId("key").textContent;

    view.rerender(<Harness state={{ status: "retry" }} />);
    expect(screen.getByTestId("key")).toHaveTextContent(initialKey ?? "");

    view.rerender(<Harness state={{ status: "success" }} />);
    const firstSuccessKey = screen.getByTestId("key").textContent;
    expect(firstSuccessKey).not.toBe(initialKey);

    view.rerender(<Harness state={{ status: "success" }} />);
    expect(screen.getByTestId("key").textContent).not.toBe(firstSuccessKey);
  });
});
