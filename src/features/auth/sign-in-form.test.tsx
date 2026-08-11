import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { SignInForm } from "./sign-in-form";

describe("SignInForm", () => {
  it("presents Arabic email sign-in controls and sends the email", async () => {
    const onRequestSignIn = vi.fn().mockResolvedValue({ status: "sent" });
    render(<SignInForm configured onRequestSignIn={onRequestSignIn} />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@voya.example" } });
    fireEvent.click(screen.getByRole("button", { name: "أرسل رابط الدخول" }));

    expect(onRequestSignIn).toHaveBeenCalledWith("operator@voya.example");
    expect(await screen.findByText("أرسلنا رابطًا آمنًا إلى بريدك الإلكتروني.")) .toBeInTheDocument();
  });

  it("explains and disables sign-in when Supabase is not configured", () => {
    render(<SignInForm configured={false} onRequestSignIn={vi.fn()} />);

    expect(screen.getByText("الدخول غير مهيأ في هذه البيئة بعد.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "أرسل رابط الدخول" })).toBeDisabled();
  });

  it("explains when magic-link requests are temporarily rate limited", async () => {
    const onRequestSignIn = vi.fn().mockResolvedValue({ status: "rate_limited" });
    render(<SignInForm configured onRequestSignIn={onRequestSignIn} />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@voya.example" } });
    fireEvent.click(screen.getByRole("button", { name: "أرسل رابط الدخول" }));

    expect(await screen.findByText("الرابط السابق قد يظل صالحًا. استخدم أحدث رابط وصلك، أو جرّب الدخول بكلمة المرور.")).toBeInTheDocument();
  });

  it("recovers from a rejected action transport and allows a successful retry", async () => {
    const onRequestSignIn = vi.fn()
      .mockRejectedValueOnce(new Error("Failed to find Server Action"))
      .mockResolvedValueOnce({ status: "sent" });
    render(<SignInForm configured onRequestSignIn={onRequestSignIn} />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@voya.example" } });
    fireEvent.click(screen.getByRole("button", { name: "أرسل رابط الدخول" }));

    expect(await screen.findByText("تعذّر إرسال الرابط الآن. حاول مرة أخرى بعد قليل.")).toBeInTheDocument();
    const retryButton = screen.getByRole("button", { name: "أرسل رابط الدخول" });
    expect(retryButton).toBeEnabled();

    fireEvent.click(retryButton);

    await waitFor(() => expect(onRequestSignIn).toHaveBeenCalledTimes(2));
    expect(await screen.findByText("أرسلنا رابطًا آمنًا إلى بريدك الإلكتروني.")).toBeInTheDocument();
  });

  it("does not impose an extra client-side wait after a provider rate limit", async () => {
    const onRequestSignIn = vi.fn().mockResolvedValue({ status: "rate_limited" });
    render(<SignInForm configured onRequestSignIn={onRequestSignIn} />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@voya.example" } });
    fireEvent.click(screen.getByRole("button", { name: "أرسل رابط الدخول" }));

    expect(await screen.findByText("الرابط السابق قد يظل صالحًا. استخدم أحدث رابط وصلك، أو جرّب الدخول بكلمة المرور.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "أرسل رابط الدخول" })).toBeEnabled();
  });
});
