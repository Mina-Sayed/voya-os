# Runbook: `verify` CI job fails on a PR

**Means:** the quality gate (lint, typecheck, tests, build, DB suite, audit, scanners)
rejected the head SHA. Never merge over it, never weaken the gate to pass it.

**First check (name the failing step, not just the job):**
```bash
gh run view <RUN_ID> --json jobs --jq '.jobs[] | select(.conclusion=="failure") | .steps[] | select(.conclusion=="failure") | .name'
```
Known signatures and their fixes:
- `snyk/...` + `SNYK-0005` → dead `SNYK_TOKEN` secret. Owner rotates it in
  `gh secret set SNYK_TOKEN`, then re-run failed jobs.
- `snyk/...` + `Not Found (SNYK-CLI-0000)` → token valid but Snyk account has no
  org/project. Owner-side Snyk dashboard fix; re-run after.
- `npm audit ... exit code 1` → real advisories. Bump the named package within a
  safe range (`npm audit fix`, never `--force`), re-audit to zero, push.
- `GitGuardian Security Checks` fail in ~1s → dashboard incidents, not code hunches.
  Read the incident list (file + detector). Test-fixture literals (`"secret-password"`
  shape) get replaced with runtime-built values; real leaks get rotated first.
- Anything else → read the step log (`gh run view <RUN_ID> --log-failed`), fix
  forward on the PR branch, push, watch green.

**Then:** confirm the full `verify` run is green on the final head SHA before merge
(`gh pr checks <N>`). A green run on an older SHA proves nothing about the new head.

**Escalate to:** repo owner for secret rotation, dashboard triage, or account fixes.
Red security gates are never bypassed with admin merge.
