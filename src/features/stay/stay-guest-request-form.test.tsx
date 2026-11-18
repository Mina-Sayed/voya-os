import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { StayGuestRequestForm } from "./stay-guest-request-form";

afterEach(() => vi.unstubAllGlobals());

describe("Stay guest request form", () => {
  it("requires at least one contact method and explicit consent before sending", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    render(<StayGuestRequestForm slug="stay-a101" privacyNoticeUrl="https://voya.example/privacy" privacyNoticeVersion="privacy-v1" />);

    fireEvent.change(screen.getByLabelText("الاسم الكامل"), { target: { value: "ضيف VOYA" } });
    fireEvent.change(screen.getByLabelText("تاريخ الوصول"), { target: { value: "2027-03-01" } });
    fireEvent.change(screen.getByLabelText("تاريخ المغادرة"), { target: { value: "2027-03-04" } });
    fireEvent.change(screen.getByLabelText("عدد الضيوف"), { target: { value: "2" } });
    fireEvent.click(screen.getByRole("button", { name: "إرسال طلب للمراجعة" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("اكتب رقم هاتف أو بريدًا إلكترونيًا للتواصل معك.");
    expect(fetchMock).not.toHaveBeenCalled();

    fireEvent.change(screen.getByLabelText(/رقم الهاتف/u), { target: { value: "01012345678" } });
    fireEvent.click(screen.getByRole("button", { name: "إرسال طلب للمراجعة" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("وافق على إشعار الخصوصية قبل إرسال الطلب.");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("submits a request and confirms receipt without claiming a booking", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 201,
      json: async () => ({ status: "received", message: "وصل طلبك إلى الفريق للمراجعة. لم يتم تأكيد الحجز." }),
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<StayGuestRequestForm
      slug="stay-a101"
      initialCheckIn="2027-03-01"
      initialCheckOut="2027-03-04"
      initialGuests={2}
      privacyNoticeUrl="https://voya.example/privacy"
      privacyNoticeVersion="privacy-v1"
    />);

    fireEvent.change(screen.getByLabelText("الاسم الكامل"), { target: { value: "ضيف VOYA" } });
    fireEvent.change(screen.getByLabelText(/رقم الهاتف/u), { target: { value: "01012345678" } });
    fireEvent.click(screen.getByRole("checkbox", { name: /أوافق أن تتواصل VOYA/u }));
    fireEvent.click(screen.getByRole("button", { name: "إرسال طلب للمراجعة" }));

    expect(await screen.findByRole("status")).toHaveTextContent("لم يتم تأكيد الحجز");
    expect(fetchMock).toHaveBeenCalledWith("/api/stay/requests", expect.objectContaining({
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
    }));
    const sentBody = JSON.parse(fetchMock.mock.calls[0]?.[1]?.body as string) as Record<string, unknown>;
    expect(sentBody).toMatchObject({ slug: "stay-a101", name: "ضيف VOYA", phone: "01012345678", guests: 2, consent: true });
  });
});

it("preserves the entered request and requires consent again when the notice changes", async () => {
  const fetchMock = vi.fn().mockResolvedValueOnce({
    ok: false,
    status: 409,
    json: async () => ({
      code: "consent_notice_changed",
      message: "راجع الإشعار الجديد",
      notice: { url: "https://voya.example/privacy-v2", version: "privacy-v2" },
    }),
  }).mockResolvedValueOnce({
    ok: true,
    status: 201,
    json: async () => ({ status: "received", message: "وصل طلبك" }),
  });
  vi.stubGlobal("fetch", fetchMock);
  render(<StayGuestRequestForm slug="stay-a101" initialCheckIn="2027-03-01" initialCheckOut="2027-03-04"
    privacyNoticeUrl="https://voya.example/privacy" privacyNoticeVersion="privacy-v1" />);
  fireEvent.change(screen.getByLabelText("الاسم الكامل"), { target: { value: "ضيف VOYA" } });
  fireEvent.change(screen.getByLabelText(/رقم الهاتف/), { target: { value: "01012345678" } });
  const checkbox = screen.getByRole("checkbox");
  const submit = screen.getByRole("button", { name: "إرسال طلب للمراجعة" });
  fireEvent.click(checkbox);
  fireEvent.click(submit);
  expect(await screen.findByRole("alert")).toHaveTextContent("راجع الإشعار الجديد");
  expect(checkbox).not.toBeChecked();
  expect(screen.getByLabelText("الاسم الكامل")).toHaveValue("ضيف VOYA");
  expect(screen.getByRole("link", { name: "إشعار الخصوصية" })).toHaveAttribute("href", "https://voya.example/privacy-v2");
  fireEvent.click(submit);
  expect(fetchMock).toHaveBeenCalledTimes(1);
  fireEvent.click(checkbox);
  fireEvent.click(submit);
  expect(await screen.findByRole("status")).toHaveTextContent("وصل طلبك");
  expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toMatchObject({ consent: true, consent_version: "privacy-v2" });
});
