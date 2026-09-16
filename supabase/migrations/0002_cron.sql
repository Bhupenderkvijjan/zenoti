-- ════════════════════════════════════════════════════════════
--  Nightly schedule for zenoti-sync, run entirely inside Supabase.
--  Requires the "pg_cron" and "pg_net" extensions (enable both from
--  Database → Extensions in the Supabase dashboard before running this).
-- ════════════════════════════════════════════════════════════
create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

-- Runs daily at 18:00 UTC = 23:30 IST, syncing "yesterday" for all active
-- companies/centers — same default the old local dashboard used.
-- Replace the two placeholders below before running:
--   <PROJECT_REF>      e.g. abcdefghijklmnop
--   <SYNC_TRIGGER_SECRET>  the same value you set with `supabase secrets set`
select cron.schedule(
  'zenoti-nightly-sync',
  '0 18 * * *',
  $$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/zenoti-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer <SYNC_TRIGGER_SECRET>'
    ),
    body := jsonb_build_object('mode', 'daily')
  );
  $$
);

-- To change the schedule or remove it later:
--   select cron.unschedule('zenoti-nightly-sync');
--   select * from cron.job;               -- list schedules
--   select * from cron.job_run_details;   -- run history / failures
