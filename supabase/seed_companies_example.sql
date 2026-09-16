-- ════════════════════════════════════════════════════════════
--  Run this once in the Supabase SQL Editor (or via `supabase db execute`)
--  after 0001_init.sql, with your real values filled in.
--  Your Zenoti API keys are already sitting in the DEFAULT_COMPANIES
--  block of the old zenoti_sync_manager.html — copy them from there.
--  Do NOT commit real keys into git; keep this file local.
-- ════════════════════════════════════════════════════════════

insert into zenoti_companies (slug, name, api_key, active) values
  ('jcb',    'JCB Company', '<PASTE JCB API KEY HERE>',    true),
  ('spalon', 'Spalon',      '<PASTE SPALON API KEY HERE>', true)
on conflict (slug) do update set api_key = excluded.api_key, name = excluded.name;

-- Add every center for each brand. One row per center_id.
-- (The old tool had an empty `centers: []` for both — pull the real
-- center GUIDs from your Zenoti org / the Trica sync scripts.)
insert into zenoti_centers (company_slug, center_id, center_name, active) values
  ('jcb',    '<JCB CENTER 1 GUID>',    'JCB - Center Name',    true),
  ('jcb',    '<JCB CENTER 2 GUID>',    'JCB - Center Name',    true),
  -- ... repeat for all 18 JCB centers
  ('spalon', '<SPALON CENTER 1 GUID>', 'Spalon - Center Name', true)
  -- ... repeat for all Spalon centers
on conflict (company_slug, center_id) do nothing;
