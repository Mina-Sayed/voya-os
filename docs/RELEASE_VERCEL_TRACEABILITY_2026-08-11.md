# Vercel release traceability — 2026-08-11

## Candidate

- Project: `voya-os` (`prj_9eg8OuaIL3hthyNcTqzNHMMLaJka`).
- Release branch: `codex/release-20260811`.
- Candidate source is a clean worktree at commit `2c97e4e`, based on
  `e6a7ae2`, with the service-role auth limiter adapter, SSR MFA token fix,
  stale-refresh-cookie handling, canonical managed migration filenames,
  typecheck CI step, PostCSS lockfile update, and generated Vercel-output lint
  exclusion. The MFA enrollment action now resets only interrupted,
  unverified TOTP factors before creating a fresh QR enrollment. The root
  route also bridges legacy `/?code=...` and `/?token_hash=...` links to the
  internal `/auth/callback` endpoint without accepting an external target.
  The sign-in form also no longer adds a client-side 60-second retry countdown
  after Supabase rejects a magic-link request.
- Preview deployment verified READY at:
  `https://voya-ohiksxej5-minas-projects-ed065580.vercel.app`.
- Preview deployment ID: `dpl_Cu2MYCHPTcmdxLFV3kNNbMzKcmAF`.
- The enrollment regression is covered by unit tests. The QA account was
  subsequently verified with MFA, so the latest live smoke correctly reaches
  `/security/mfa?reason=challenge`; no verified factor was removed to force a
  second QR enrollment test.

## Production

- Production alias: `https://voya-os.vercel.app`.
- Current production deployment: `dpl_8kahW92SAuvhLcdmq8kQRvLjGiNa`.
- Production status: **READY**, verified with `/api/health` (200), public
  `/workspace` redirect to `/sign-in`, root `/?code=...` bridge to
  `/auth/callback`, and direct inspection of the deployed sign-in chunks. The
  new magic-link copy is present and the old countdown strings are absent.
- The production deployment has `gitSource: null`; branch/commit traceability
  is maintained by this release branch and its GitHub pull request.

## Environment correction

`AUTH_RATE_LIMIT_HMAC_SECRET` was missing from both Preview and Production.
Separate randomly generated sensitive values were added to each Vercel
environment without printing them. Preview was rebuilt after the correction.

Managed Supabase Auth logs on 2026-08-11 show repeated `/otp` requests rejected
with HTTP 429 and `over_email_send_rate_limit` before delivery. This provider
limit is separate from the removed browser countdown. The same logs report a
localhost referrer for production-origin requests, while the Vercel
`VOYA_APP_URL` is verified as `https://voya-os.vercel.app`; managed Auth Site
URL/redirect configuration therefore needs reconciliation. Custom production
SMTP remains unverified and magic-link delivery is not production-ready.

The first Preview smoke reached the sign-in action and exposed the code/managed
grant mismatch. After the adapter switched to the server-only service-role
client, the SSR MFA call was also corrected to pass the access token explicitly
for tokens-only cookies. The final Preview was rebuilt and promoted only after
the authenticated smoke passed.

## Promotion rule

Production promotion is performed only from the exact READY prebuilt artifact
after the authenticated smoke is verified. Vercel manual CLI deployments have
no Git source linkage (`gitSource` is null); branch/commit traceability is kept
in this release branch and the GitHub pull request until Vercel Git integration
is configured.
