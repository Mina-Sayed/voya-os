import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { GoogleSignInButton } from "./google-sign-in-button";

describe("GoogleSignInButton", () => {
  it("is disabled when provider configuration is unavailable", () => {
    render(<GoogleSignInButton configured={false} onSignIn={vi.fn()} />);
    expect(screen.getByRole("button", { name: "متابعة باستخدام Google" })).toBeDisabled();
    expect(screen.getByText("تسجيل الدخول عبر Google غير مهيأ في هذه البيئة بعد.")).toBeInTheDocument();
  });

  it("shows a retry message when the provider request throws", async () => {
    const onSignIn = vi.fn().mockRejectedValue(new Error("provider unavailable"));
    render(<GoogleSignInButton configured onSignIn={onSignIn} />);

    fireEvent.click(screen.getByRole("button", { name: "متابعة باستخدام Google" }));

    await screen.findByText("تعذّر تسجيل الدخول عبر Google الآن. حاول مرة أخرى بعد قليل.");
    expect(onSignIn).toHaveBeenCalledOnce();
    await waitFor(() => expect(screen.getByRole("button", { name: "متابعة باستخدام Google" })).toBeEnabled());
  });

  it("renders the provider result returned by the sign-in boundary", async () => {
    const onSignIn = vi.fn().mockResolvedValue({ status: "retry" });
    render(<GoogleSignInButton configured onSignIn={onSignIn} />);

    fireEvent.click(screen.getByRole("button", { name: "متابعة باستخدام Google" }));

    await screen.findByText("تعذّر تسجيل الدخول عبر Google الآن. حاول مرة أخرى بعد قليل.");
    expect(onSignIn).toHaveBeenCalledOnce();
  });
});
