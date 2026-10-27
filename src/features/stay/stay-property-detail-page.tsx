import type { Metadata } from "next";
import Link from "next/link";
import { ArrowLeft, BadgeInfo, Images, MapPin, ShieldCheck } from "lucide-react";
import type { StayDemoExample } from "./stay-demo-content";
import { stayDemoExamples } from "./stay-demo-content";
import { StayDemoGallery } from "./stay-demo-gallery";
import { StaySiteFrame } from "./voya-stay-home-page";
import styles from "./stay-search-pages.module.css";
import homeStyles from "./stay-home-page.module.css";

export function stayDemoDetailMetadata(example: StayDemoExample): Metadata {
  return {
    title: `${example.title} — تفاصيل توضيحية | VOYA Stay`,
    description: "صفحة تفاصيل بصرية تجريبية، وليست وحدة إقامة معروضة للحجز.",
  };
}

export function StayPropertyDetailPage({
  example,
}: Readonly<{ example: StayDemoExample }>) {
  const galleryImages = stayDemoExamples.map(({ alt, image, title }) => ({
    alt,
    src: image,
    title,
  }));
  const activeIndex = stayDemoExamples.findIndex((item) => item.slug === example.slug);

  return (
    <StaySiteFrame mode="detail">
      <div className={styles.detailPage} id="detail">
        <nav aria-label="مسار التنقل" className={styles.breadcrumb}>
          <Link href="/">الرئيسية</Link>
          <span aria-hidden="true">/</span>
          <Link href="/stay/search#examples">نماذج الإقامة</Link>
          <span aria-hidden="true">/</span>
          <span aria-current="page">تفاصيل توضيحية</span>
        </nav>

        <header className={styles.detailHeader}>
          <div>
            <p className={homeStyles.sectionEyebrow}>VOYA STAY · تفاصيل توضيحية</p>
            <h1>{example.title}</h1>
            <p>هذه صفحة لتوضيح شكل تفاصيل الإقامة فقط، ولا تصف وحدة فعلية.</p>
          </div>
          <span className={styles.detailDemoBadge}>
            <Images aria-hidden="true" />
            مثال بصري
          </span>
        </header>

        <div className={styles.detailGrid}>
          <StayDemoGallery images={galleryImages} initialIndex={activeIndex} />

          <aside aria-labelledby="detail-information-title" className={styles.detailNotice}>
            <span aria-hidden="true" className={styles.detailNoticeIcon}>
              <BadgeInfo />
            </span>
            <p className={styles.detailNoticeEyebrow}>معاينة محلية فقط</p>
            <h2 id="detail-information-title">بيانات الوحدة غير متاحة</h2>
            <p className={styles.detailNoticeText}>
              الصورة والمسمى للتوضيح. لا ترتبط هذه الصفحة بعقار أو سعر أو موقع أو توافر فعلي.
            </p>
            <dl className={styles.detailFacts}>
              <div>
                <dt><Images aria-hidden="true" /> الصور</dt>
                <dd>توضيحية</dd>
              </div>
              <div>
                <dt><MapPin aria-hidden="true" /> الموقع</dt>
                <dd>غير محدد</dd>
              </div>
              <div>
                <dt><ShieldCheck aria-hidden="true" /> السعر والتوافر</dt>
                <dd>غير معروضين أو متحققين</dd>
              </div>
            </dl>
            <p className={styles.detailNoBooking}>
              طلب الإقامة والحجز غير متاحين من هذه المعاينة.
            </p>
            <Link className={styles.detailBackLink} href="/stay/search#examples">
              العودة إلى نماذج الإقامة
              <ArrowLeft aria-hidden="true" className={homeStyles.inlineIcon} />
            </Link>
          </aside>
        </div>

        <section aria-labelledby="detail-boundary-title" className={styles.detailBoundary}>
          <p className={homeStyles.sectionEyebrow}>حدود المثال</p>
          <h2 id="detail-boundary-title">المعلومات المؤكدة هي أساس أي اختيار</h2>
          <p>
            ربط صور أو بطاقات الإقامة بمخزون VOYA يحتاج إلى بيانات نشر معتمدة. لذلك لا تعرض هذه الصفحة
            أعداد غرف أو سعة ضيوف أو أسعاراً أو تقييماً.
          </p>
        </section>
      </div>
    </StaySiteFrame>
  );
}
