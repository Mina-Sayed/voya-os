import { describe, expect, test } from "vitest";
import { detectWhatsappReplyReview } from "./whatsapp-reply-review";

describe("detectWhatsappReplyReview", () => {
  test("returns no reasons for ordinary conversational replies", () => {
    expect(detectWhatsappReplyReview("أهلاً بيك في VOYA، تحب أساعدك في إيه؟")).toEqual([]);
    expect(detectWhatsappReplyReview("عشان أراجعلك، ممكن تبعتلي تاريخ الوصول؟")).toEqual([]);
    expect(detectWhatsappReplyReview("تمام، هحول طلبك لفريق المبيعات حالاً.")).toEqual([]);
  });

  test("allows small counts and dates that are not money", () => {
    expect(detectWhatsappReplyReview("الشقة فيها ٣ غرف وحمامين")).toEqual([]);
    expect(detectWhatsappReplyReview("ممكن الحجز يوم 26 الشهر الجاي؟")).toEqual([]);
    expect(detectWhatsappReplyReview("عشان 5 أشخاص")).toEqual([]);
  });

  test("flags monetary amounts written in arabic digits", () => {
    expect(detectWhatsappReplyReview("السعر 35000 جنيه شهرياً")).toEqual(["monetary_amount"]);
    expect(detectWhatsappReplyReview("تمام، ١٢٠٠٠ ريال")).toEqual(["monetary_amount"]);
    expect(detectWhatsappReplyReview("الإجمالي 35 ألف جنيه")).toEqual(["monetary_amount"]);
  });

  test("flags monetary amounts written in latin digits or symbols", () => {
    expect(detectWhatsappReplyReview("It costs $250 per night")).toEqual(["monetary_amount"]);
    expect(detectWhatsappReplyReview("Total is 1200 EGP")).toEqual(["monetary_amount"]);
  });

  test("flags booking commitments in arabic and english", () => {
    expect(detectWhatsappReplyReview("تم حجز الشقة لك")).toEqual(["booking_commitment"]);
    expect(detectWhatsappReplyReview("تم تأكيد الحجز")).toEqual(["booking_commitment"]);
    expect(detectWhatsappReplyReview("سجّلنا طلبك في النظام")).toEqual(["booking_commitment"]);
    expect(detectWhatsappReplyReview("Your booking is confirmed")).toEqual(["booking_commitment"]);
  });

  test("flags availability statements", () => {
    expect(detectWhatsappReplyReview("الشقة متاحة")).toEqual(["availability_commitment"]);
    expect(detectWhatsappReplyReview("This one is available now")).toEqual(["availability_commitment"]);
  });

  test("reports every matched reason in a stable order", () => {
    expect(detectWhatsappReplyReview("تم حجزها بسعر 35000 جنيه")).toEqual([
      "booking_commitment",
      "monetary_amount",
    ]);
    expect(detectWhatsappReplyReview("تم حجزها بسعر 35000 جنيه")).toEqual(
      detectWhatsappReplyReview("تم حجزها بسعر 35000 جنيه"),
    );
  });

  test("is case insensitive for english terms", () => {
    expect(detectWhatsappReplyReview("BOOKING CONFIRMED")).toEqual(["booking_commitment"]);
    expect(detectWhatsappReplyReview("AVAILABLE")).toEqual(["availability_commitment"]);
  });

  test("treats empty and missing replies as nothing to review", () => {
    expect(detectWhatsappReplyReview(null)).toEqual([]);
    expect(detectWhatsappReplyReview(undefined)).toEqual([]);
    expect(detectWhatsappReplyReview("   ")).toEqual([]);
  });
});
// Regressions found by the independent security review (2026-10-19): each input
// below was auto-delivered before these rules existed.
describe("detectWhatsappReplyReview — security review regressions", () => {
  test("catches availability claims phrased as vacant, free or bookable", () => {
    for (const reply of [
      "الغرفة شاغرة",
      "الوحدة خالية من الأحد",
      "الغرفة فارغة",
      "ما عليه أي حجز",
      "الوحدة متبقية",
      "تقدر تحجزها دلوقتي",
      "The unit is fine for Sunday",
      "This one is open next week",
    ]) {
      expect(detectWhatsappReplyReview(reply), reply).toEqual(["availability_commitment"]);
    }
  });

  test("catches a price spelled out in words with no digits at all", () => {
    for (const reply of [
      "السعر ثلاثون ألف جنيه",
      "السعر خمسون ألف دولار",
      "المبلغ خمسة وثلاثون ألف جنيه للليلة",
    ]) {
      expect(detectWhatsappReplyReview(reply), reply).toEqual(["monetary_amount"]);
    }
  });

  test("catches terms split by invisible formatting characters", () => {
    expect(detectWhatsappReplyReview("الوحدة مت\u200Bاحة من الأحد")).toEqual(["availability_commitment"]);
    expect(detectWhatsappReplyReview("الوحدة مت\u200Cاحة من الأحد")).toEqual(["availability_commitment"]);
    expect(detectWhatsappReplyReview("الوحدة مت\u200Dاحة من الأحد")).toEqual(["availability_commitment"]);
    expect(detectWhatsappReplyReview("الوحدة مت\u200Eاحة من الأحد")).toEqual(["availability_commitment"]);
    expect(detectWhatsappReplyReview("الوادة مت\u00ADاح من الأحد")).toEqual(["availability_commitment"]);
    expect(detectWhatsappReplyReview("الوحدة مت\uFEFFاحة من الأحد")).toEqual(["availability_commitment"]);
  });

  test("catches booking commitments that use the definite article or other verbs", () => {
    expect(detectWhatsappReplyReview("تم التأكيد وسيتم تسجيل طلبك")).toEqual(["booking_commitment"]);
    expect(detectWhatsappReplyReview("سجلت طلبك في النظام")).toEqual(["booking_commitment"]);
    expect(detectWhatsappReplyReview("Your reservation is confirmed")).toEqual(["booking_commitment"]);
  });
});
