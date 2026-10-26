export type StayDemoExample = Readonly<{
  slug: string;
  image: string;
  alt: string;
  title: string;
  note: string;
  description: string;
}>;

export const stayDemoExamples: readonly StayDemoExample[] = [
  {
    slug: "living-room-concept",
    image: "/images/demo/stay-living-room.webp",
    alt: "صورة توضيحية لمساحة معيشة مفروشة، وليست وحدة فعلية",
    title: "مساحة معيشة مفتوحة",
    note: "تصوّر بصري فقط",
    description: "تصوّر بصري لمساحة مفروشة — لا يرتبط بوحدة أو عرض فعلي.",
  },
  {
    slug: "quiet-bedroom-concept",
    image: "/images/demo/stay-bedroom.webp",
    alt: "صورة توضيحية لغرفة نوم في إقامة مفروشة، وليست وحدة فعلية",
    title: "ركن هادئ للإقامة",
    note: "تصوّر بصري فقط",
    description: "صورة توضيحية للعرض فقط، ولا تعكس بيانات إقامة فعلية.",
  },
  {
    slug: "family-space-concept",
    image: "/images/demo/stay-studio.webp",
    alt: "صورة توضيحية لاستوديو مفروش، وليست وحدة فعلية",
    title: "تصوّر لمساحة عائلية",
    note: "تصوّر بصري فقط",
    description: "نموذج بصري لبطاقة الإقامة، من دون سعة أو سعر أو توافر.",
  },
] as const;

export function findStayDemoExample(slug: string): StayDemoExample | undefined {
  return stayDemoExamples.find((example) => example.slug === slug);
}
