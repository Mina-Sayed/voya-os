import { fireEvent, render, screen } from "@testing-library/react";
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

    expect(await screen.findByText("تم طلب روابط كثيرة. انتظر دقيقة ثم استخدم أحدث رابط فقط.")).toBeInTheDocument();
  });
});
