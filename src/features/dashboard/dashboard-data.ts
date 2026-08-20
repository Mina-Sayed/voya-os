import { createOrganizationId, type OrganizationId } from "@/domain/tenancy/organization";

export type DashboardMetric = Readonly<{
  label: string;
  value: string;
  change: string;
  tone: "teal" | "sand" | "coral";
}>;

export type DashboardBooking = Readonly<{
  id: string;
  organizationId: OrganizationId;
  property: string;
  guest: string;
  checkIn: string;
  checkOut: string;
  status: "confirmed" | "pending_approval";
  stayLabel: string;
}>;

export type DashboardApproval = Readonly<{
  id: string;
  organizationId: OrganizationId;
  title: string;
  detail: string;
  requestedBy: string;
  requestedAt: string;
  urgency: "normal" | "attention";
}>;

export type DashboardData = Readonly<{
  isPreview: boolean;
  organizationId: OrganizationId;
  organizationName: string;
  operatorName: string;
  dateLabel: string;
  dateRangeLabel: string;
  metrics: readonly DashboardMetric[];
  bookings: readonly DashboardBooking[];
  approvals: readonly DashboardApproval[];
}>;

const organizationId = createOrganizationId("org-voya-demo");

export const dashboardData: DashboardData = {
  isPreview: true,
  organizationId,
  organizationName: "فُويا للإقامات",
  operatorName: "ليان أحمد",
  dateLabel: "الثلاثاء، ٢١ يوليو",
  dateRangeLabel: "JUL 21 — JUL 27",
  metrics: [
    {
      label: "الإشغال هذا الأسبوع",
      value: "86٪",
      change: "+8٪ عن الأسبوع الماضي",
      tone: "teal",
    },
    {
      label: "وصولات اليوم",
      value: "4",
      change: "شقتان تحتاجان فحصًا أخيرًا",
      tone: "sand",
    },
    {
      label: "قرارات معلّقة",
      value: "3",
      change: "قرار واحد يحتاج انتباهك",
      tone: "coral",
    },
  ],
  bookings: [
    {
      id: "booking-1008",
      organizationId,
      property: "روف النيل · Zamalek 4B",
      guest: "سارة منصور",
      checkIn: "2026-07-21",
      checkOut: "2026-07-25",
      status: "confirmed",
      stayLabel: "اليوم ← الجمعة",
    },
    {
      id: "booking-1012",
      organizationId,
      property: "دار الياسمين · Maadi 12",
      guest: "كريم عادل",
      checkIn: "2026-07-21",
      checkOut: "2026-07-24",
      status: "confirmed",
      stayLabel: "اليوم ← الخميس",
    },
    {
      id: "booking-1015",
      organizationId,
      property: "بيت أزور · New Cairo 7",
      guest: "نور حسام",
      checkIn: "2026-07-22",
      checkOut: "2026-07-27",
      status: "pending_approval",
      stayLabel: "غدًا ← الأحد",
    },
  ],
  approvals: [
    {
      id: "approval-901",
      organizationId,
      title: "تعديل موعد مغادرة",
      detail: "روف النيل · Zamalek 4B · من ٢٥ إلى ٢٦ يوليو",
      requestedBy: "مروان، العمليات",
      requestedAt: "منذ ١٨ دقيقة",
      urgency: "attention",
    },
    {
      id: "approval-902",
      organizationId,
      title: "إغلاق توفر للصيانة",
      detail: "بيت أزور · New Cairo 7 · ٢٨–٢٩ يوليو",
      requestedBy: "رنا، العمليات",
      requestedAt: "منذ ٤٦ دقيقة",
      urgency: "normal",
    },
    {
      id: "approval-903",
      organizationId,
      title: "تسوية مالك جاهزة للمراجعة",
      detail: "يوليو ٢٠٢٦ · لم يتم ترحيل أي قيد",
      requestedBy: "هالة، المحاسبة",
      requestedAt: "منذ ساعة",
      urgency: "normal",
    },
  ],
};
