"use client";

import Image from "next/image";
import { useState } from "react";
import styles from "./stay-search-pages.module.css";

export type StayDemoGalleryImage = Readonly<{
  src: string;
  alt: string;
  title: string;
}>;

export function StayDemoGallery({
  images,
  initialIndex = 0,
}: Readonly<{
  images: readonly StayDemoGalleryImage[];
  initialIndex?: number;
}>) {
  const safeInitialIndex = Math.min(Math.max(initialIndex, 0), images.length - 1);
  const [activeIndex, setActiveIndex] = useState(safeInitialIndex);
  const activeImage = images[activeIndex];

  if (!activeImage) return null;

  return (
    <div aria-label="معرض الصور التوضيحية" className={styles.gallery} role="group">
      <figure className={styles.galleryFigure}>
        <div className={styles.galleryMainImage}>
          <Image
            alt={activeImage.alt}
            className={styles.galleryImage}
            fill
            preload
            sizes="(max-width: 900px) 92vw, 62vw"
            src={activeImage.src}
          />
          <span className={styles.galleryDemoLabel}>صورة توضيحية</span>
        </div>
        <figcaption aria-live="polite" className={styles.galleryCaption}>
          {activeImage.title} · صورة ضمن المعاينة فقط
        </figcaption>
      </figure>
      <div aria-label="اختيار صورة توضيحية" className={styles.galleryThumbs}>
        {images.map((image, index) => (
          <button
            aria-label={`عرض صورة توضيحية: ${image.title}`}
            aria-pressed={activeIndex === index}
            className={`${styles.galleryThumb} ${activeIndex === index ? styles.galleryThumbActive : ""}`}
            key={image.src}
            onClick={() => setActiveIndex(index)}
            type="button"
          >
            <Image alt="" fill sizes="120px" src={image.src} />
          </button>
        ))}
      </div>
    </div>
  );
}
