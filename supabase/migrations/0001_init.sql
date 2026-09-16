-- ════════════════════════════════════════════════════════════
--  Zenoti Sales Report → Supabase sync
--  Schema: config tables + sales fact table + sync logs
-- ════════════════════════════════════════════════════════════

-- ── COMPANY CONFIG (replaces hardcoded API keys in the old HTML tool) ──
create table if not exists zenoti_companies (
  slug        text primary key,          -- 'jcb', 'spalon'
  name        text not null,
  api_key     text not null,             -- Zenoti API key, server-side only
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists zenoti_centers (
  id            uuid primary key default gen_random_uuid(),
  company_slug  text not null references zenoti_companies(slug) on delete cascade,
  center_id     uuid not null,           -- Zenoti center_id (GUID)
  center_name   text,
  active        boolean not null default true,
  unique (company_slug, center_id)
);

-- ── SALES FACT TABLE (one row per invoice line item) ──
-- Field list reconciled from Zenoti's /v1/sales/salesreport response schema.
create table if not exists zenoti_sales (
  invoice_item_id           uuid primary key,   -- Zenoti's own unique row id: safe upsert key
  company_slug              text not null references zenoti_companies(slug),
  center_id                 uuid not null,

  invoice_no                text,
  receipt_no                text,
  guest_id                  uuid,
  guest_name                text,
  guest_code                text,
  sold_on                   timestamptz,
  serviced_on                timestamptz,

  center_name               text,
  center_code                text,

  item_type                 text,
  item_name                 text,
  item_code                  text,
  gift_card_code             text,

  quantity                  numeric,
  unit_price                numeric,
  sale_price                numeric,
  discount                  numeric,
  final_sale_price           numeric,
  total_tax                  numeric,
  tax_code                   text,

  loyalty_point_redemption   numeric,
  membership_redemption      numeric,
  prepaid_card_redemption    numeric,
  cashback_redemption        numeric,
  package_redemption         numeric,

  cash                       numeric,
  card                       numeric,
  check_amount               numeric,   -- source field is "check" (reserved-ish word) -> renamed
  custom                     numeric,
  points                     numeric,
  membership_paid            numeric,
  prepaid_card               numeric,
  due                        numeric,

  last_payment_date          timestamptz,
  rounding_adjustment        numeric,
  tips                       numeric,

  employee_name               text,
  employee_code                text,
  employee_job_code            text,

  tags                       text,
  promotion                  text,
  coupon_printed              text,
  first_visit                 text,
  package                    text,
  package_invoice             text,
  payment_type                text,
  business_unit_name           text,
  state_code                  text,
  sac                        text,
  hsn                        text,
  created_date_in_center       timestamptz,
  item_row_num                int,
  row_num                    int,

  raw                        jsonb,        -- full original API row, for anything not mapped above
  synced_at                  timestamptz not null default now()
);

create index if not exists idx_zenoti_sales_company on zenoti_sales (company_slug);
create index if not exists idx_zenoti_sales_center on zenoti_sales (center_id);
create index if not exists idx_zenoti_sales_sold_on on zenoti_sales (sold_on);

-- ── SYNC RUN LOG (what the dashboard used to show as "last sync" / status pill) ──
create table if not exists zenoti_sync_logs (
  id            bigint generated always as identity primary key,
  company_slug  text,
  center_id     uuid,
  start_date    date,
  end_date      date,
  status        text not null,       -- 'running' | 'success' | 'error'
  rows_synced   int default 0,
  error_message text,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz
);

-- ════════════════════════════════════════════════════════════
--  RLS — nothing here is meant to be public.
--  The Edge Function talks to Postgres with the service_role key,
--  which bypasses RLS entirely. Anon/authenticated keys get nothing
--  unless you explicitly add read-only policies later for a dashboard.
-- ════════════════════════════════════════════════════════════
alter table zenoti_companies enable row level security;
alter table zenoti_centers   enable row level security;
alter table zenoti_sales     enable row level security;
alter table zenoti_sync_logs enable row level security;

-- (No policies created — service_role only, by default, until you add some.)
