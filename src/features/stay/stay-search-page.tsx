import type { Metadata } from "next";
import Link from "next/link";
import { ArrowLeft, BadgeInfo, House, Sparkles } from "lucide-react";
import { StayConceptCard } from "./stay-concept-card";
import { stayDemoExamples } from "./stay-demo-content";
import { StaySiteFrame } from "./voya-stay-home-page";
import { StayPublicListingCard } from "./stay-public-listing-card";
import type { StaySearchCriteria, VoyaStayPublicListing } from "@/lib/stay/public-catalog";
import styles from "./stay-search-pages.module.css";
import homeStyles from "./stay-home-page.module.css";

export const metadata: Metadata = {
  title: "إقامات منشورة | VOYA Stay",
  description: "ابحث بين الإقامات التي اختار فريق VOYA نشرها على VOYA Stay.",
};

export const demoMetadata: Metadata = {
  title: "نماذج الإقامة التوضيحية | VOYA Stay",
  description: "أمثلة بصرية توضيحية لبطاقات الإقامة في VOYA Stay.",
};

export function StayLiveSearchPage({
  criteria,
  listings,
  invalidSearch = false,
}: Readonly<{ criteria: StaySearchCriteria; listings: readonly VoyaStayPublicListing[]; invalidSearch?: boolean }>) {
  const summary = [
    criteria.destination ? `المنطقة: ${criteria.destination}` : null,
    criteria.checkIn && criteria.checkOut ? `الفترة: ${criteria.checkIn} ← ${criteria.checkOut}` : null,
    criteria.guests !== null ? `الضيوف: ${criteria.guests}` : null,
  ].filter(Boolean).join(" · ");

  return (
    <StaySiteFrame mode="search">
      <section aria-labelledby="live-search-title" className={styles.liveResultsIntro} id="results">
        <div className={styles.pageInner}>
          <nav aria-label="مسار التنقل" className={styles.breadcrumb}>
            <Link href="/">الرئيسية</Link>
            <span aria-hidden="true">/</span>
            <span aria-current="page">الإقامات المنشورة</span>
          </nav>
          <div className={styles.liveResultsHeader}>
            <div>
              <p className={homeStyles.sectionEyebrow}>VOYA STAY · كتالوج منشور</p>
              <h1 id="live-search-title">{invalidSearch ? "تحقق من معايير البحث" : "اختر الإقامة المناسبة لرحلتك"}</h1>
              <p>{invalidSearch ? "تأكد من أن تاريخ المغادرة يأتي بعد الوصول، وأن عدد الضيوف ضمن النطاق المسموح." : summary || "تصفح الإقامات التي وافق فريق VOYA على عرضها."}</p>
              <Link className={styles.searchAgainLink} href="/#stay-search">
                تعديل البحث
                <ArrowLeft aria-hidden="true" className={homeStyles.inlineIcon} />
              </Link>
            </div>
            <aside className={styles.liveResultsNote}>
              التوفر المبيّن إرشادي من سجل الإشغال عند إجراء البحث. إرسال طلب إقامة يطلب مراجعة الفريق فقط، ولا يؤكد الحجز أو يحجز التواريخ.
            </aside>
          </div>
        </div>
      </section>

      <section aria-labelledby="live-listings-title" className={styles.liveResults}>
        <div className={styles.pageInner}>
          <div className={styles.liveResultsHeading}>
            <div>
              <p>إقامات راجعها فريق VOYA</p>
              <h2 id="live-listings-title">{listings.length} إقامة منشورة</h2>
            </div>
            <span className={styles.exampleListMark}>لا أسعار أو تقييمات غير معتمدة</span>
          </div>
          {listings.length === 0 ? (
            <div className={styles.liveEmptyState}>
              <h2>{invalidSearch ? "تعذر البحث بهذه المعايير" : "لا توجد إقامات منشورة تطابق البحث"}</h2>
              <p>{invalidSearch ? "عدّل بيانات البحث ثم أعد المحاولة." : "جرّب منطقة أخرى أو عدّل التواريخ وعدد الضيوف. لا تعرض VOYA Stay وحدات غير معتمدة."}</p>
            </div>
          ) : (
            <div className={homeStyles.conceptGrid}>
              {listings.map((listing, index) => <StayPublicListingCard eager={index === 0} key={listing.slug} listing={listing} />)}
            </div>
          )}
          <div className={styles.resultDisclaimer}>
            <House aria-hidden="true" />
            <p>كل نتيجة منشورة صراحة من فريق العقارات. التوفر إرشادي، وأي طلب يحتاج مراجعة قبل تأكيد الإقامة.</p>
          </div>
        </div>
      </section>
    </StaySiteFrame>
  );
}

export function StaySearchExamplesPage() {
  return (
    <StaySiteFrame mode="search">
      <section aria-labelledby="search-examples-title" className={styles.searchIntro} id="results">
        <div className={styles.pageInner}>
          <nav aria-label="مسار التنقل" className={styles.breadcrumb}>
            <Link href="/">الرئيسية</Link>
            <span aria-hidden="true">/</span>
            <span aria-current="page">نماذج الإقامة</span>
          </nav>
          <div className={styles.searchIntroGrid}>
            <div className={styles.searchIntroCopy}>
              <p className={homeStyles.sectionEyebrow}>VOYA STAY · معاينة</p>
              <h1 id="search-examples-title">نماذج الإقامة التوضيحية</h1>
              <p>
                شاهد كيف يمكن أن تظهر بطاقات الإقامة. هذه أمثلة بصرية فقط، وليست نتائج بحث أو وحدات متاحة.
              </p>
              <Link className={styles.searchAgainLink} href="/#stay-search">
                جرّب حقول البحث التوضيحية
                <ArrowLeft aria-hidden="true" className={homeStyles.inlineIcon} />
              </Link>
            </div>
            <aside aria-label="تنبيه المعاينة" className={styles.previewNote}>
              <span aria-hidden="true" className={styles.previewNoteIcon}>
                <BadgeInfo />
              </span>
              <div>
                <h2>لا توجد نتائج فعلية</h2>
                <p>لا تعرض هذه الصفحة سعراً أو تقييماً أو موقعاً أو توافراً.</p>
              </div>
            </aside>
          </div>
        </div>
      </section>

      <section aria-labelledby="example-list-title" className={styles.exampleList} id="examples">
        <div className={styles.pageInner}>
          <div className={styles.exampleListHeading}>
            <div>
              <p className={homeStyles.sectionEyebrow}>صور توضيحية · غير قابلة للحجز</p>
              <h2 id="example-list-title">مساحات للإلهام البصري</h2>
            </div>
            <span className={styles.exampleListMark}>
              <Sparkles aria-hidden="true" />
              أمثلة تصميمية فقط
            </span>
          </div>

          <div className={homeStyles.conceptGrid}>
            {stayDemoExamples.map((example, index) => (
              <StayConceptCard
                detailHref={`/stay/property/${example.slug}`}
                eager={index === 0}
                example={example}
                key={example.slug}
              />
            ))}
          </div>

          <div className={styles.resultDisclaimer}>
            <House aria-hidden="true" />
            <p>كل بطاقة وصورة في هذه الصفحة توضيحية، ولا تشير إلى عقار أو خدمة فعلية.</p>
          </div>
        </div>
      </section>
    </StaySiteFrame>
  );
}
