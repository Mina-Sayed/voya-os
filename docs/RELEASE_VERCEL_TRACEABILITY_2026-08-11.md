# Vercel release traceability — 2026-08-11

## Candidate

- Project: `voya-os` (`prj_9eg8OuaIL3hthyNcTqzNHMMLaJka`).
- Release branch: `codex/release-20260811`.
- Candidate source is a clean worktree based on commit `e6a7ae2`, with the
  service-role auth limiter adapter, canonical managed migration filenames,
  typecheck CI step, and PostCSS lockfile update.
- Preview deployment currently verified READY at:
  `https://voya-8nibqhg79-minas-projects-ed065580.vercel.app`.
- Deployment ID: `dpl_FxcWNumAK4uCtz8FYzRKfRpV44eT`.

## Environment correction

`AUTH_RATE_LIMIT_HMAC_SECRET` was missing from both Preview and Production.
Separate randomly generated sensitive values were added to each Vercel
environment without printing them. Preview was rebuilt after the correction.

The first Preview smoke reached the sign-in action and exposed the code/managed
grant mismatch. After the adapter switched to the server-only service-role
client, the next deployment was rebuilt and is the promotion candidate.

## Promotion rule

Production promotion is performed only from the exact READY prebuilt artifact
after the authenticated smoke is verified. Vercel manual CLI deployments have
no Git source linkage (`gitSource` is null); branch/commit traceability is kept
in this release branch and the GitHub pull request until Vercel Git integration
is configured.
