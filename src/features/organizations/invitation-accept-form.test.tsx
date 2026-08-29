import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { InvitationAcceptForm } from "./invitation-accept-form";

const navigation = vi.hoisted(() => ({ replace: vi.fn() }));
vi.mock("next/navigation", () => ({ useRouter: () => ({ replace: navigation.replace }) }));

afterEach(() => navigation.replace.mockReset());

describe("InvitationAcceptForm", () => {
  it("uses client-side navigation after accepting an invitation", async () => {
    const action = vi.fn().mockResolvedValue({ status: "success", message: "تم القبول." });
    render(<InvitationAcceptForm action={action} token="valid-token" />);

    fireEvent.click(screen.getByRole("button", { name: "قبول الدعوة وفتح مساحة العمل" }));

    await waitFor(() => expect(navigation.replace).toHaveBeenCalledWith("/workspace"));
  });
});
