# Zenoti Sales Report → Supabase sync

Cloud-only replacement for the old `zenoti_sync_manager.html` tool. No local
PC or IP address involved anywhere — Postgres stores the data, a Supabase
Edge Function does the fetching, GitHub Actions deploys code changes
automatically, and a hosted dashboard (GitHub Pages) lets you trigger manual
syncs from any device.

**API covered right now:** only `GET /v1/sales/salesreport` (per-center,
per-item sales rows). Note Zenoti's docs mark this endpoint **deprecated** —
"not to use this API for any new integrations as the data cannot be
reconciled to new sales accrual/sales cash reports." It still works today,
but Zenoti could retire it eventually; the accrual/cash `flat_file` report
APIs are their suggested replacement if this one ever breaks.

## What's in this repo

```
.github/workflows/
  deploy-supabase.yml     -- auto-deploys function + migrations on every push to main
docs/
  index.html              -- the manual sync dashboard, served by GitHub Pages
supabase/
  migrations/
    0001_init.sql          -- tables: zenoti_companies, zenoti_centers, zenoti_sales, zenoti_sync_logs
    0002_cron.sql           -- nightly schedule (pg_cron + pg_net)
  functions/zenoti-sync/
    index.ts                -- the Edge Function that does the actual sync
  seed_companies_example.sql -- template to load JCB/Spalon + their centers (fill in and run once, don't commit real keys)
```

## One-time setup

### 1. Create the GitHub repo
Push this folder to a **private** repository (keep it private — even
though real API keys live in Supabase, not in this code, no reason to make
it public).

Easiest way if you don't use git day-to-day: on github.com, **New
repository** → drag-and-drop every file/folder from this download into the
"upload files" screen → commit. Or with git:
```bash
git init
git add .
git commit -m "initial commit"
git branch -M main
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

### 2. Get your Supabase access token
Go to [supabase.com/dashboard/account/tokens](https://supabase.com/dashboard/account/tokens)
→ **Generate new token** → copy it (you won't see it again).

### 3. Add GitHub repo secrets
In your repo: **Settings → Secrets and variables → Actions → New repository secret**.
Add three:
| Name | Value |
|---|---|
| `SUPABASE_ACCESS_TOKEN` | the token from step 2 |
| `SUPABASE_PROJECT_REF` | `orgvftwvifhbciyzeboh` (from your project URL) |
| `SUPABASE_DB_PASSWORD` | your project's database password (Settings → Database in Supabase, or reset it there) |

### 4. Push once — this deploys everything automatically
Now that the secrets are set, any push to `main` that touches
`supabase/functions/**` or `supabase/migrations/**` runs the workflow in
`.github/workflows/deploy-supabase.yml`, which:
- links to your Supabase project
- runs `supabase db push` (applies migrations)
- runs `supabase functions deploy zenoti-sync --no-verify-jwt`

Check the **Actions** tab in GitHub to watch it run and confirm it succeeded.
You can also trigger it manually anytime from Actions → Deploy to Supabase → **Run workflow**.

### 5. Load your companies + centers (one-time, done in Supabase directly)
This step still happens in the Supabase SQL Editor, not through GitHub —
real API keys should never be committed to the repo. Open
`supabase/seed_companies_example.sql`, fill in your real JCB/Spalon keys and
center IDs, and run it once in the SQL Editor.

### 6. Set the trigger secret
In Supabase: **Edge Functions → Secrets** → add `SYNC_TRIGGER_SECRET` with
a long random value. This guards the function's public URL so only callers
who know the secret (you, cron) can trigger a sync.

### 7. Enable GitHub Pages for the dashboard
In your repo: **Settings → Pages** → Source: **Deploy from a branch** →
Branch: `main`, folder: `/docs` → Save. After a minute, your dashboard is
live at `https://<you>.github.io/<repo>/` — open it from any phone,
tablet, or computer.

First time you open it: click **⚙ Connection settings**, paste in your
`SYNC_TRIGGER_SECRET` (the function URL is pre-filled). It's saved per
browser via localStorage — you'll enter it once on each device you use.

## Using it day to day

**Automatic:** the nightly cron job (`0002_cron.sql`, currently 18:00 UTC /
11:30 PM IST) calls the function with `{"mode":"daily"}`, which always pulls
**yesterday only** — nothing else. Change the cron expression in that file
and push to `main` to update the schedule (or edit it directly via
Supabase's **Database → Cron Jobs** UI).

**Manual:** open the dashboard, pick a company, a date range (or use the
quick buttons — Yesterday / Last 7 days / Last 30 days / Last calendar
month / This month so far), choose **Overwrite** or **Delete & Resync**,
and click Run. It automatically loops through center-batches and shows
live progress — no copy-pasting JSON.

**Making code changes:** edit `supabase/functions/zenoti-sync/index.ts` or
the migration files, commit, push to `main` — GitHub Actions deploys it
within a minute or two. No manual dashboard code-pasting needed anymore.

## Notes / things worth knowing

- **Upsert key:** `invoice_item_id` (Zenoti's own GUID for each invoice
  line) is the primary key, so re-running Overwrite mode for a range
  you've already pulled just updates those rows — safe to re-run.
- **Delete & Resync:** deletes every row matching that company + center +
  date range (by `sold_on`) before re-pulling — use when you suspect data
  is stale or wrong and want a clean slate for that period.
- **7-day chunking:** the function splits any date range into ≤7-day
  windows internally (Zenoti's hard limit on this endpoint).
- **Center batching:** each invocation processes a capped number of
  centers (default 6, dashboard uses 4) to stay inside the Edge Function's
  time/memory limits; anything left over comes back as `next_request` in
  the response, which the dashboard auto-continues.
- **`serviced_on` fix:** for non-service line items (products,
  memberships, gift cards — `item_type !== 0`), Zenoti returns a dummy
  `0001-01-01` date; the function replaces it with `sold_on` instead. Real
  services keep their genuine appointment date.
- **Known Zenoti-side issue:** center `4fb3b021-8542-4b5b-89f7-652ea9659c14`
  (JCB) returns a genuine `401 Unauthorized` from Zenoti — not a bug here,
  worth checking that center's access under this API key in Zenoti's own
  dashboard.
