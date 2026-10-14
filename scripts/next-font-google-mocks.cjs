// Local authenticated E2E builds use installed fonts when outbound Google
// Fonts access is unavailable. Production builds continue to use the normal
// Next.js font downloader and the same named font families.
const localFontCss = (family, localFonts, subset) => `/* ${subset} */
@font-face {
  font-family: '${family}';
  font-style: normal;
  font-weight: 100 900;
  font-display: swap;
  src: ${localFonts.map((font) => `local("${font}")`).join(", ")};
}`;

module.exports = {
  "https://fonts.googleapis.com/css2?family=Noto+Kufi+Arabic:wght@100..900&display=swap": localFontCss(
    "Noto Kufi Arabic",
    ["Noto Kufi Arabic", "Noto Sans Arabic", "Arial"],
    "arabic",
  ),
  "https://fonts.googleapis.com/css2?family=Geist+Mono:wght@100..900&display=swap": localFontCss(
    "Geist Mono",
    ["Geist Mono", "DejaVu Sans Mono", "monospace"],
    "latin",
  ),
};
