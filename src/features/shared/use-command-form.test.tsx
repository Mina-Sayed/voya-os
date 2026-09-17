import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { useCommandForm } from "./use-command-form";

type State = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  resetIdempotencyKey?: boolean;
}>;

function Harness({ state }: Readonly<{ state: State }>) {
  const { formRef, idempotencyKey } = useCommandForm(state);
  return <form ref={formRef}><input aria-label="name" defaultValue="" name="name" /><output data-testid="key">{idempotencyKey}</output></form>;
}

describe("useCommandForm", () => {
  it("keeps the key for retry, denied, and ordinary invalid results", () => {
    const view = render(<Harness state={{ status: "idle" }} />);
    const initialKey = screen.getByTestId("key").textContent;

    for (const status of ["retry", "denied", "invalid"] as const) {
      view.rerender(<Harness state={{ status }} />);
      expect(screen.getByTestId("key")).toHaveTextContent(initialKey ?? "");
    }
  });

  it("rotates only an explicitly poisoned invalid key without clearing user edits", () => {
    const view = render(<Harness state={{ status: "idle" }} />);
    const initialKey = screen.getByTestId("key").textContent;
    const input = screen.getByLabelText("name") as HTMLInputElement;
    fireEvent.change(input, { target: { value: "corrected value" } });

    view.rerender(<Harness state={{ status: "invalid", resetIdempotencyKey: true }} />);

    expect(screen.getByTestId("key").textContent).not.toBe(initialKey);
    expect((screen.getByLabelText("name") as HTMLInputElement).value).toBe("corrected value");
  });

  it("rotates the key and clears the form after success", () => {
    const view = render(<Harness state={{ status: "idle" }} />);
    const initialKey = screen.getByTestId("key").textContent;
    fireEvent.change(screen.getByLabelText("name"), { target: { value: "saved" } });

    view.rerender(<Harness state={{ status: "success" }} />);

    expect(screen.getByTestId("key").textContent).not.toBe(initialKey);
    expect((screen.getByLabelText("name") as HTMLInputElement).value).toBe("");
  });
});
