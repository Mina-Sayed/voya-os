import type { AgentKind, MembershipRole } from "./tool-policy";

export type AgentDefinition = Readonly<{
  kind: AgentKind;
  label: string;
  description: string;
  mode: "preview" | "disabled";
  roles: readonly MembershipRole[];
}>;

export const AGENT_REGISTRY: readonly AgentDefinition[] = [
  {
    kind: "copilot",
    label: "مساعد فُويا",
    description: "يقرأ ملخص تشغيل مؤسستك ويقترح أولويات قابلة للمراجعة دون تنفيذ أي إجراء.",
    mode: "preview",
    roles: ["owner", "manager", "sales_agent", "operations"],
  },
  {
    kind: "sales",
    label: "مساعد المبيعات",
    description: "يقرأ الطلبات والعقارات والتوفر ليقترح متابعة قابلة للمراجعة.",
    mode: "preview",
    roles: ["owner", "manager", "sales_agent"],
  },
  {
    kind: "booking",
    label: "مساعد الإقامات",
    description: "يشرح التعارضات ويجهز اقتراح إقامة دون تأكيد أو حجز تلقائي.",
    mode: "preview",
    roles: ["owner", "manager", "sales_agent", "operations"],
  },
  {
    kind: "manager",
    label: "ملخص المدير",
    description: "يلخص قائمة العمل والقرارات الظاهرة لدورك مع روابط للمصدر.",
    mode: "preview",
    roles: ["owner", "manager"],
  },
  {
    kind: "data_entry",
    label: "مساعد إدخال البيانات",
    description: "يجهز مسودة عملاء وعقارات من النص والصور لمراجعتك قبل الحفظ.",
    mode: "preview",
    roles: ["owner", "manager", "sales_agent", "operations"],
  },
  {
    kind: "finance",
    label: "مساعد المالية",
    description: "غير مفعّل حتى اعتماد قواعد المحاسبة والتسويات ومراجعة البيانات.",
    mode: "disabled",
    roles: ["owner", "manager", "accountant"],
  },
];

export function visibleAgentDefinitions(role: MembershipRole): readonly AgentDefinition[] {
  return AGENT_REGISTRY.filter((agent) => agent.roles.includes(role));
}
