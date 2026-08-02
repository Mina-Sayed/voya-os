import { createOrganizationId, type OrganizationId } from "@/domain/tenancy/organization";

export type DashboardMetric = Readonly<{
  label: string;
  value: string;
  change: string;
  tone: "teal" | "sand" | "coral";
}>;

export type DashboardLead = Readonly<{
  id: string;
  organizationId: OrganizationId;
  title: string;
  source: string;
  status: string;
  requestedCheckIn: string | null;
  requestedCheckOut: string | null;
  createdAt: string;
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
  metrics: readonly DashboardMetric[];
  recentLeads: readonly DashboardLead[];
  approvals: readonly DashboardApproval[];
}>;

const organizationId = createOrganizationId("org-voya-demo");

export const dashboardData: DashboardData = {
  isPreview: true,
  organizationId,
  organizationName: "فُويا للإقامات",
  operatorName: "ليان أحمد",
  dateLabel: "الثلاثاء، ٢١ يوليو",
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
  recentLeads: [
    {
      id: "lead-1008",
      organizationId,
      title: "إقامة عائلية في الزمالك",
      source: "website",
      status: "new",
      requestedCheckIn: "2026-07-21",
      requestedCheckOut: "2026-07-25",
      createdAt: "2026-07-21T08:30:00Z",
    },
    {
      id: "lead-1012",
      organizationId,
      title: "طلب شقة عمل في المعادي",
      source: "referral",
      status: "qualified",
      requestedCheckIn: "2026-07-21",
      requestedCheckOut: "2026-07-24",
      createdAt: "2026-07-21T08:10:00Z",
    },
    {
      id: "lead-1015",
      organizationId,
      title: "إقامة قصيرة في القاهرة الجديدة",
      source: "walk_in",
      status: "awaiting_match",
      requestedCheckIn: "2026-07-22",
      requestedCheckOut: "2026-07-27",
      createdAt: "2026-07-21T07:45:00Z",
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
