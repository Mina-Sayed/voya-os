# Runbook: SMTP delivery and MFA policy

Operational steps for Supabase Auth email and MFA. Nothing here is automated
by migrations. Every step is a managed-console or account action. Never paste
credentials into the repository, tickets, or chat.

## 1. Symptom: password reset fails (SMTP 535)

Evidence: `docs/memory/CURRENT_STATE.md` records Gmail answering
`535 5.7.8 Username and Password not accepted` and Supabase returning HTTP 500
(last seen 2026-10-05). The app now logs these as
`{"event":"operational_failure","operation":"auth.password_reset","code":"password_reset_delivery_failed","request_id":...}`.

### 1a. Quick fix: rotate the Gmail App Password
1. Sign in to the Google account used as the SMTP sender. Confirm Security → 2-Step Verification is on.
2. Go to Security → App passwords, create a new one (for example, name it "Supabase Auth"), and copy it once.
3. Supabase Dashboard (production project) → Authentication → Emails → SMTP Settings:
   - host `smtp.gmail.com`, port `587`
   - username = the full Gmail address
   - password = the new App Password
   - sender email = the same Gmail address (it must match the username)
   - Save.
4. Revoke the previous App Password in Google.
5. Test: request a reset at `/forgot-password` for a staff account. Supabase → Logs → Auth must show no `535`, and the app logs must show no `password_reset_delivery_failed`.

### 1b. Recommended: move Supabase Auth SMTP to Resend on our own domain
1. Resend → Domains → add the sending domain (for example, `mail.<company-domain>`).
2. Add the DNS records Resend shows: **SPF** (TXT/MX for the bounce subdomain) and **DKIM** (TXT/CNAME). Wait until the domain shows "Verified".
3. Add **DMARC**: TXT `_dmarc.<domain>` = `v=DMARC1; p=none; rua=mailto:<ops-mailbox>`. Move to `p=quarantine` after a clean week.
4. Create a Resend API key restricted to sending.
5. Supabase → Authentication → Emails → SMTP Settings:
   - host `smtp.resend.com`, port `465` (or `587`)
   - username `resend`, password = API key
   - sender `no-reply@<domain>`
6. Keep Authentication → Rate Limits → "Send OTPs or magic links" at 15–30 seconds (not zero).
7. Test the reset again (step 1a.5). Invitations use the same provider through `RESEND_API_KEY` / `RESEND_FROM` / `RESEND_ENABLED` (outbox worker). Enabling them is a separate, explicit decision.

## 2. MFA policy (decided for V1)

- MFA (TOTP, AAL2) is **mandatory for every role**. It's already enforced in `src/domain/auth/mfa-policy.ts`, the workspace gates, and `public.require_workspace_aal2_v1()` in the database.
- **Owners and managers are recommended to keep two verified authenticators** (for example, a phone app plus a password-manager TOTP). Supabase TOTP has no backup codes, so the second factor is the recovery path. This is guidance, not an enforced rule: `src/domain/auth/mfa-policy.ts` takes only (`currentLevel`, `verifiedFactorCount`) and the actions cap every role at two factors, so a single-factor owner is not flagged as non-compliant anywhere in the product.
  - Add it from Workspace → Security → "إضافة تطبيق احتياطي" (`/security/mfa?add=backup`).
  - This requires a current AAL2 session. Maximum two verified factors.
- **Backup owner account:** keep a second `owner` membership, held by a different person, with a strong unique password plus TOTP, stored in the company password manager. It isn't used day to day.
- **Session settings:** keep the current values (`jwt_expiry=3600`, refresh-token rotation). `secure_password_change=true` is set in `supabase/config.toml`, which only configures the **local** auth stack (`project_id = "voya-os-auth-e2e"`). Do **not** enable "Secure password change" in the managed project yet: the only password-change path is `src/app/auth/recovery/actions.ts`, which calls `updateUser({ password })` with neither `current_password` nor a fresh `nonce`. If the managed semantics require either, password recovery breaks and the user only sees a generic failure. Prove the reset flow first (request reset → open link → set password against a disposable stack); then enable it and record the dated result here.

### Reset procedure (lost device)
1. The requester contacts an owner through a known channel (call or video). Confirm identity. Never accept a reset request by email alone.
2. That owner opens Supabase Dashboard → Authentication → Users → the user → **MFA factors**, and deletes only the lost factor.
3. If the user still has their second factor, they keep working and re-add a backup.
4. If no factor remains, the user signs in and is sent to enrollment automatically.
5. Record the reset (who, when, why) in the ops log.

## 3. Applying missing production migrations safely

Production lagged (92/126 at 2026-10-09). Before the next promotion:
1. Confirm a current restore point (PITR or a fresh backup) for the production project and note its timestamp.
2. **Deploy the application artifact before applying this set.** `20261016200000` drops the four-argument `consume_auth_rate_limit` overload, while the running artifact imports the four-argument limiter (see `docs/memory/CURRENT_STATE.md`). Applying the migration first makes the limiter raise `PGRST202`, which the adapter turns into `AuthRateLimitUnavailable`, and password sign-in, sign-up, reset, and invitation resend all fail closed until the artifact catches up. Redeploy Vercel production from the matching Git commit (not a CLI upload) and check that `/api/version` reports that SHA **before** touching the database.
3. Run `supabase db push --dry-run` against production. Compare the list with `supabase/migrations/`.
4. Apply with the approved release flow (`docs/runbooks/prod-promotion-checklist.md`), then run the read-only preflight (`docs/RELEASE_INTEGRATION_2026-10-07.md`).
5. Verify:
   - `consume_auth_rate_limit(text,text,integer,integer)` no longer exists, and no `consume_auth_rate_limit` overload is executable by `anon` or `authenticated` (K-015, migration `20261016200000`).
   - Workspace RPCs reject AAL1 sessions.
   - Password sign-in, sign-up, reset, and invitation resend still return normally (the post-apply check for step 2).
