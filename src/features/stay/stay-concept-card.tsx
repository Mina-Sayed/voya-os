import Image from "next/image";
import Link from "next/link";
import { ArrowLeft, Sparkles } from "lucide-react";
import type { StayDemoExample } from "./stay-demo-content";
import styles from "./stay-home-page.module.css";

export function StayConceptCard({
  example,
  detailHref,
  eager = false,
}: Readonly<{
  example: StayDemoExample;
  detailHref?: string;
  eager?: boolean;
}>) {
  return (
    <article className={styles.conceptCard}>
      <div className={styles.conceptImageWrap}>
        <Image
          alt={example.alt}
          className={styles.conceptImage}
          fill
          loading={eager ? "eager" : "lazy"}
          sizes="(max-width: 700px) 92vw, (max-width: 1100px) 46vw, 31vw"
          src={example.image}
        />
        <span className={styles.imageDemoTag}>
          <Sparkles aria-hidden="true" className={styles.imageDemoIcon} />
          صورة توضيحية
        </span>
      </div>
      <div className={styles.conceptCardBody}>
        <div className={styles.conceptCardMeta}>
          <span>تصوّر إقامة</span>
          <span>{example.note}</span>
        </div>
        <h3>{example.title}</h3>
        <p>{example.description}</p>
        {detailHref ? (
          <Link className={styles.conceptDetailLink} href={detailHref}>
            عرض التفاصيل التوضيحية
            <ArrowLeft aria-hidden="true" className={styles.inlineIcon} />
          </Link>
        ) : null}
      </div>
    </article>
  );
}
