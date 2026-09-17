-- ════════════════════════════════════════════════════════════
--  Reporting functions for the dashboard.
--  Unlike plain SQL views, these take a date range as a parameter —
--  that's what lets the dashboard's date picker actually work,
--  instead of being locked to "current month" like the old TBLSALES views.
--
--  Run this whole file once in the Supabase SQL Editor.
-- ════════════════════════════════════════════════════════════

-- ── 1. Sales Summary — daily totals, works for any date range/company ──
create or replace function report_sales_summary(
  p_start date,
  p_end date,
  p_company text default null
)
returns table (
  sale_date date,
  company_slug text,
  invoice_count bigint,
  total_sale_price numeric,
  total_discount numeric,
  total_tax numeric,
  total_final_sale numeric
)
language sql
security invoker
as $$
  select
    (sold_on at time zone 'UTC')::date as sale_date,
    company_slug,
    count(distinct invoice_no) as invoice_count,
    sum(sale_price) as total_sale_price,
    sum(discount) as total_discount,
    sum(total_tax) as total_tax,
    sum(final_sale_price) as total_final_sale
  from zenoti_sales
  where sold_on >= p_start
    and sold_on < (p_end + 1)
    and (p_company is null or company_slug = p_company)
  group by 1, 2
  order by 1, 2;
$$;

-- ── 2. Sales by Employee — works for any date range/company ──
create or replace function report_sales_by_employee(
  p_start date,
  p_end date,
  p_company text default null
)
returns table (
  employee_code text,
  employee_name text,
  company_slug text,
  invoice_count bigint,
  total_sale_price numeric,
  total_discount numeric,
  total_final_sale numeric
)
language sql
security invoker
as $$
  select
    employee_code,
    employee_name,
    company_slug,
    count(distinct invoice_no) as invoice_count,
    sum(sale_price) as total_sale_price,
    sum(discount) as total_discount,
    sum(final_sale_price) as total_final_sale
  from zenoti_sales
  where sold_on >= p_start
    and sold_on < (p_end + 1)
    and (p_company is null or company_slug = p_company)
    and employee_code is not null
  group by 1, 2, 3
  order by total_final_sale desc;
$$;

-- ── 3. JCB Adjustments — converted from your ALLADJUSTMENT_JCB view ──
-- Scoped to JCB only for now (the item codes/promotion strings below are
-- JCB-specific) — send me the Spalon equivalent view and I'll add a
-- matching function for it.
create or replace function report_adjustments_jcb(
  p_start date,
  p_end date
)
returns table (
  brand text,
  adjusted_type text,
  employee_code text,
  employee_name text,
  adjustment_value numeric
)
language sql
security invoker
as $$
  with base_data as (
    select
      employee_code,
      employee_name,
      coalesce(discount, 0) as discount_value
    from zenoti_sales
    where company_slug = 'jcb'
      and serviced_on >= p_start
      and serviced_on < (p_end + 1)
      and discount >= 0
      and unit_price > 0
      and promotion = 'Manual Discount:'
      and promotion not like '%Campaign%'
  ),
  walkin_matches as (
    select distinct center_id, invoice_no, (serviced_on at time zone 'UTC')::date as service_date
    from zenoti_sales
    where company_slug = 'jcb'
      and serviced_on >= p_start
      and serviced_on < (p_end + 1)
      and promotion like 'Campaign: WALK-IN WED PAIR%'
  ),
  walkin_detail as (
    select
      s.invoice_no,
      s.employee_code,
      s.employee_name,
      s.sale_price,
      s.discount,
      (coalesce(s.membership_redemption,0) + coalesce(s.prepaid_card_redemption,0) + coalesce(s.package_redemption,0)) as total_redemption,
      (coalesce(s.final_sale_price,0) - coalesce(s.total_tax,0)) as net_sale_amount
    from zenoti_sales s
    join walkin_matches m
      on s.center_id = m.center_id
     and s.invoice_no = m.invoice_no
     and (s.serviced_on at time zone 'UTC')::date = m.service_date
    where s.item_type = '0'
      and s.promotion not like '%Membership: Glow Membership%'
      and s.promotion not like '%Membership: Glow2.0%'
  ),
  walkin_totals as (
    select invoice_no, sum(sale_price) as total_unit_price, sum(discount) as total_discount
    from walkin_detail
    group by invoice_no
  ),
  walkin_base as (
    select
      d.employee_code,
      d.employee_name,
      round((d.sale_price - ((d.sale_price / nullif(t.total_unit_price,0)) * t.total_discount))::numeric, 2) as adjusted_net_sale,
      (d.net_sale_amount + d.total_redemption) as less_adjustment
    from walkin_detail d
    join walkin_totals t on d.invoice_no = t.invoice_no
  )

  select 'Jcb', 'Referrals', employee_code, employee_name, sum(discount_value) / 2
  from base_data
  group by employee_code, employee_name

  union all

  select 'Jcb', 'New Glow', employee_code, employee_name, sum(sale_price) / 2
  from zenoti_sales
  where company_slug = 'jcb'
    and serviced_on >= p_start and serviced_on < (p_end + 1)
    and item_code in ('SER-5428-008', 'SER-356-008', 'SER-860-008')
    and promotion like '%GLOW 2%'
    and final_sale_price = 0
  group by employee_code, employee_name

  union all

  select 'Jcb', 'Old Glow', employee_code, employee_name, sum(sale_price) / 2
  from zenoti_sales
  where company_slug = 'jcb'
    and serviced_on >= p_start and serviced_on < (p_end + 1)
    and item_code in ('SER-365-008', 'SER-2182-008')
    and promotion like '%Glow Membership%'
    and final_sale_price = 0
  group by employee_code, employee_name

  union all

  select 'Jcb', 'VIP', employee_code, employee_name, sum(sale_price)
  from zenoti_sales
  where company_slug = 'jcb'
    and serviced_on >= p_start and serviced_on < (p_end + 1)
    and (promotion like '%VIP100%' or promotion like '%VIP 2025 -100% Off%')
  group by employee_code, employee_name

  union all

  select 'Jcb', 'Bloggers', employee_code, employee_name, sum(sale_price) / 2
  from zenoti_sales
  where company_slug = 'jcb'
    and serviced_on >= p_start and serviced_on < (p_end + 1)
    and promotion like '%Bloggers Billing%'
  group by employee_code, employee_name

  union all

  select 'Jcb', 'WalkInWedPair', employee_code, employee_name, sum(adjusted_net_sale) - sum(less_adjustment)
  from walkin_base
  group by employee_code, employee_name

  union all

  select 'Jcb', 'LoyaltyPoint', employee_code, employee_name, sum(loyalty_point_redemption) / 2
  from zenoti_sales
  where company_slug = 'jcb'
    and serviced_on >= p_start and serviced_on < (p_end + 1)
    and loyalty_point_redemption > 0
  group by employee_code, employee_name;
$$;

-- ── Grant execute so the dashboard (anon key) can call these via RPC ──
grant execute on function report_sales_summary(date, date, text) to anon;
grant execute on function report_sales_by_employee(date, date, text) to anon;
grant execute on function report_adjustments_jcb(date, date) to anon;
