# Vivedhainfra
Construction company site

## Deployment (Vercel)
Static site with a tiny build step (`build.mjs`) that injects PUBLIC Supabase values.

| Setting | Value |
|---|---|
| Framework preset | Other |
| Build command | `npm run build` (from vercel.json) |
| Output directory | `dist` (from vercel.json) |
| Env var `SUPABASE_URL` | `https://yjsheukujiarkbulopvr.supabase.co` |
| Env var `SUPABASE_ANON_KEY` | the publishable key (`sb_publishable_...`) from Supabase > Project Settings > API Keys |

Set both variables for Production (and Preview if you want previews to show live reviews), then redeploy.
Never add the `service_role` key, a `sb_secret_...` key or the database password anywhere in this repo or in Vercel variables used by the site.

## Reviews
* Visitors submit through the database function `submit_review` (validation, HTML stripping, spam holding, rate limits).
* Only `status = 'published'` reviews are readable by the public (Row Level Security).
* Admin: open `/#review-admin`, sign in with the Supabase Auth admin user, then Approve, Reject or Delete.
* Database setup is in `supabase/migrations/`. The baseline is already applied by hand; do not re-run it blindly.
* Keep `google738f324c03d202e1.html` (Search Console verification).
