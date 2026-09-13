import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { useCommandForm } from "./use-command-form";

type State = Readonly<{ status: "idle" | "success" | "retry" | "invalid" | "denied" }>;

function Harness({ state }: Readonly<{ state: State }>) {
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form ref={formRef}><input aria-label="name" defaultValue="" name="name" /><output data-testid="key">{idempotencyKey}</output></form>;
}

describe("useCommandForm", () => {
  it("keeps a key across retries and rotates it for every new success result", () => {
    const idle = { status: "idle" } as const;
    const view = render(<Harness state={idle} />);
    const initialKey = screen.getByTestId("key").textContent;

    view.rerender(<Harness state={{ status: "retry" }} />);
    expect(screen.getByTestId("key")).toHaveTextContent(initialKey ?? "");

    view.rerender(<Harness state={{ status: "denied" }} />);
    expect(screen.getByTestId("key")).toHaveTextContent(initialKey ?? "");

    view.rerender(<Harness state={{ status: "success" }} />);
    const firstSuccessKey = screen.getByTestId("key").textContent;
    expect(firstSuccessKey).not.toBe(initialKey);

    view.rerender(<Harness state={{ status: "success" }} />);
    expect(screen.getByTestId("key").textContent).not.toBe(firstSuccessKey);
  });

  it("rotates the key after an invalid answer so an edited retry cannot loop on 23505", () => {
    const view = render(<Harness state={{ status: "idle" }} />);
    const initialKey = screen.getByTestId("key").textContent;

    view.rerender(<Harness state={{ status: "invalid" }} />);
    expect(screen.getByTestId("key").textContent).not.toBe(initialKey ?? "");
  });

  it("preserves user edits on invalid but clears the form on success", () => {
    const view = render(<Harness state={{ status: "idle" }} />);
    const input = screen.getByLabelText("name") as HTMLInputElement;
    fireEvent.change(input, { target: { value: "user edit" } });
    expect(input.value).toBe("user edit");

    view.rerender(<Harness state={{ status: "invalid" }} />);
    expect((screen.getByLabelText("name") as HTMLInputElement).value).toBe("user edit");

    view.rerender(<Harness state={{ status: "success" }} />);
    expect((screen.getByLabelText("name") as HTMLInputElement).value).toBe("");
  });
});
