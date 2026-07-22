# Dependency Override Security Review

**Review date:** 2026-07-22
**Scope:** `next`/`sharp` production dependency graph.

## Finding

`next@16.2.11` installed optional `sharp@0.34.5`, which had two high-severity inherited libvips findings. The official audit fixer proposed an incompatible downgrade of Next to 9.3.3.

## Remediation

`package.json` now declaratively overrides Sharp to `0.35.3`. `npm audit --omit=dev --audit-level=high` reports no high or critical finding after the change. Lint, unit/component, database integration, browser E2E, and production build all passed with the override.

## Residual risk

Two moderate PostCSS findings remain inside Next's transitive dependency. No safe automated update is currently offered. CI retains the high/critical gate, and the override must be reassessed on every Next upgrade.
