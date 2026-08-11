# Voya OS Preview Verification

Git-based Vercel Preview deployments are the supported way to verify this branch with the project Preview environment configuration.

The Preview environment must contain these values in Vercel Project Settings:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
- `VOYA_APP_URL`
- `SUPABASE_SERVICE_ROLE_KEY` (server-only sensitive variable)

`SUPABASE_SERVICE_ROLE_KEY` must never be committed or exposed through a `NEXT_PUBLIC_*` variable. After changing Preview variables, trigger a new Git-based Preview deployment before testing `/sign-in` and protected `/workspace/*` routes.
