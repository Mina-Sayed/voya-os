# Authentication Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a server-owned Supabase authentication configuration boundary and Arabic-first sign-in screen for users of platform-provisioned organizations.

**Architecture:** Server code validates Supabase public configuration before creating a client. The sign-in form calls a server action that validates input, refuses unconfigured environments without leaking secrets, and requests an OTP email from the Supabase adapter. The fixture dashboard remains public preview-only until a later authenticated tenant data slice replaces it.

**Tech Stack:** Next.js App Router, TypeScript, React, Tailwind CSS, `@supabase/ssr`, Vitest, Testing Library.

## Global Constraints

- Organizations are platform-provisioned initially; no self-service organization or owner bootstrap command is enabled.
- Only `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` are accepted in the browser-facing configuration; service-role credentials are never read by client code.
- No booking, financial, approval, audit, or organization mutation is exposed through the sign-in flow.
- Arabic is default with English-compatible semantics, keyboard focus, error direction, reduced motion, and responsive layout.

---

### Task 1: Validated public Supabase configuration

**Files:**
- Create: `src/lib/supabase/public-config.ts`
- Create: `src/lib/supabase/public-config.test.ts`

- [x] Write failing tests for a complete config, missing values, and a URL that is not HTTPS in production.
- [x] Implement `readSupabasePublicConfig(environment)` returning a typed result or a safe `SupabaseConfigurationError`.
- [x] Run `npm run test -- src/lib/supabase/public-config.test.ts` and commit the green unit.

### Task 2: Server-owned magic-link request

**Files:**
- Create: `src/features/auth/request-sign-in.ts`
- Create: `src/features/auth/request-sign-in.test.ts`
- Create: `src/app/sign-in/actions.ts`

- [x] Write failing tests for normalized email validation, unconfigured environment failure, and the adapter invocation with a trusted redirect URL.
- [x] Implement the port and application service; the Next server action builds no tenant or role context and returns generic, non-enumerating feedback.
- [x] Run the focused test set and commit the green unit.

### Task 3: Arabic sign-in experience

**Files:**
- Create: `src/app/sign-in/page.tsx`
- Create: `src/features/auth/sign-in-form.tsx`
- Create: `src/features/auth/sign-in-form.test.tsx`
- Modify: `src/app/globals.css`

- [x] Write a failing component test for Arabic labels, email input, submit action, and safe configuration state.
- [x] Implement the responsive sign-in screen using the Voya keycard marker and established palette.
- [x] Run focused component tests, lint, E2E/build, and visually inspect desktop/mobile rendering.

### Task 4: Documentation and quality gate

**Files:**
- Modify: `README.md`
- Create: `docs/SECURITY_REVIEW_AUTH_BOUNDARY.md`

- [x] Document required nonsecret environment variables, platform provisioning assumption, cookie/redirect hardening remaining for a production callback, and test evidence.
- [x] Run full lint, coverage, database integration, E2E, build, npm audit, and scanner evidence.
- [x] Commit only after `git diff --check` passes.
