// ════════════════════════════════════════════════════════════
//  zenoti-sync
//  Pulls GET /v1/sales/salesreport from Zenoti and upserts rows
//  into the `zenoti_sales` table in Supabase Postgres.
//  Runs entirely on Supabase's servers — no local PC/IP involved.
//
//  Invoke with a JSON body:
//    { "mode": "daily" }                                   -> yesterday, all active companies/centers
//    { "mode": "backfill", "days": 30 }                    -> last N days, all active companies/centers
//    { "mode": "custom", "start_date": "2026-08-01",
//      "end_date": "2026-08-31", "company_slug": "jcb" }   -> explicit range, optional company filter
//    add "center_ids": [...] to target specific centers, "centers_per_call": N to change batch size
//    add "delete_before_sync": true to delete existing rows for that company/center/date range
//    before pulling fresh data (a full "delete & resync"), instead of the default upsert/overwrite.
// ════════════════════════════════════════════════════════════

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TRIGGER_SECRET = Deno.env.get("SYNC_TRIGGER_SECRET");

const ZENOTI_BASE = "https://api.zenoti.com/v1";
const MAX_WINDOW_DAYS = 7;
const UPSERT_BATCH_SIZE = 500;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// CORS: lets a browser page (the dashboard) call this function directly.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function fmt(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function addDays(d: Date, n: number): Date {
  const copy = new Date(d);
  copy.setUTCDate(copy.getUTCDate() + n);
  return copy;
}

function chunkDateRange(start: Date, end: Date): Array<{ start: string; end: string }> {
  const chunks: Array<{ start: string; end: string }> = [];
  let cursor = new Date(start);
  while (cursor <= end) {
    const windowEnd = new Date(Math.min(addDays(cursor, MAX_WINDOW_DAYS - 1).getTime(), end.getTime()));
    chunks.push({ start: fmt(cursor), end: fmt(windowEnd) });
    cursor = addDays(windowEnd, 1);
  }
  return chunks;
}

async function fetchSalesReport(apiKey: string, centerId: string, startDate: string, endDate: string) {
  const url = new URL(`${ZENOTI_BASE}/sales/salesreport`);
  url.searchParams.set("center_id", centerId);
  url.searchParams.set("start_date", startDate);
  url.searchParams.set("end_date", endDate);
  url.searchParams.set("item_type", "7");
  url.searchParams.set("status", "2");

  const res = await fetch(url.toString(), {
    method: "GET",
    headers: {
      Authorization: `apikey ${apiKey}`,
      Accept: "application/json",
    },
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`Zenoti API ${res.status} for center ${centerId} (${startDate}..${endDate}): ${body.slice(0, 500)}`);
  }

  const data = await res.json();
  if (Array.isArray(data?.center_sales_report)) return data.center_sales_report;
  if (Array.isArray(data)) return data;
  if (Array.isArray(data?.sales)) return data.sales;
  return [];
}

function mapRow(companySlug: string, centerId: string, r: any) {
  const itemType = r.item?.type;
  const servicedOn = itemType === 0 ? (r.serviced_on ?? null) : (r.sold_on ?? null);

  return {
    invoice_item_id: r.invoice_item_id,
    company_slug: companySlug,
    center_id: centerId,
    invoice_no: r.invoice_no ?? null,
    receipt_no: r.receipt_no ?? null,
    guest_id: r.guest?.guest_id ?? null,
    guest_name: r.guest?.guest_name ?? null,
    guest_code: r.guest?.guest_code ?? null,
    sold_on: r.sold_on ?? null,
    serviced_on: servicedOn,
    center_name: r.center?.center_name ?? null,
    center_code: r.center?.center_code ?? null,
    item_type: r.item?.type != null ? String(r.item.type) : null,
    item_name: r.item?.name ?? null,
    item_code: r.item?.code ?? null,
    gift_card_code: r.gift_card_code ?? null,
    quantity: r.quantity ?? null,
    unit_price: r.unit_price ?? null,
    sale_price: r.sale_price ?? null,
    discount: r.discount ?? null,
    final_sale_price: r.final_sale_price ?? null,
    total_tax: r.total_tax ?? null,
    tax_code: r.tax_code ?? null,
    loyalty_point_redemption: r.loyalty_point_redemption ?? null,
    membership_redemption: r.membership_redmption ?? null,
    prepaid_card_redemption: r.prepaid_card_redemption ?? null,
    cashback_redemption: r.cashback_redemption ?? null,
    package_redemption: r.package_redemption ?? null,
    cash: r.cash ?? null,
    card: r.card ?? null,
    check_amount: r.check ?? null,
    custom: r.custom ?? null,
    points: r.points ?? null,
    membership_paid: r.membership_paid ?? null,
    prepaid_card: r.prepaid_card ?? null,
    due: r.due ?? null,
    last_payment_date: r.last_payment_date ?? null,
    rounding_adjustment: r.rounding_adjustment ?? null,
    tips: r.tips ?? null,
    employee_name: r.employee?.name ?? null,
    employee_code: r.employee?.code ?? null,
    employee_job_code: r.employee?.job_code ?? null,
    tags: r.tags ?? null,
    promotion: r.promotion ?? null,
    coupon_printed: r.coupon_printed ?? null,
    first_visit: r.first_visit ?? null,
    package: r.package ?? null,
    package_invoice: r.package_invoice ?? null,
    payment_type: r.payment_type ?? null,
    business_unit_name: r.business_unit_name ?? null,
    state_code: r.state_code ?? null,
    sac: r.SAC ?? null,
    hsn: r.HSN ?? null,
    created_date_in_center: r.created_date_in_center ?? null,
    item_row_num: r.item_row_num ?? null,
    row_num: r.row_num ?? null,
    raw: r,
    synced_at: new Date().toISOString(),
  };
}

async function upsertRows(rows: any[]) {
  let written = 0;
  for (let i = 0; i < rows.length; i += UPSERT_BATCH_SIZE) {
    const batch = rows.slice(i, i + UPSERT_BATCH_SIZE);
    const { error } = await supabase.from("zenoti_sales").upsert(batch, { onConflict: "invoice_item_id" });
    if (error) throw new Error(`Supabase upsert failed: ${error.message}`);
    written += batch.length;
  }
  return written;
}

// Deletes existing rows for one center within [startDate, endDate] inclusive,
// based on sold_on. Used for "delete & resync" instead of the default upsert.
async function deleteExistingRows(companySlug: string, centerId: string, startDate: Date, endDate: Date) {
  const rangeStart = startDate.toISOString();
  const rangeEnd = addDays(endDate, 1).toISOString(); // exclusive upper bound
  const { error } = await supabase
    .from("zenoti_sales")
    .delete()
    .eq("company_slug", companySlug)
    .eq("center_id", centerId)
    .gte("sold_on", rangeStart)
    .lt("sold_on", rangeEnd);
  if (error) throw new Error(`Delete before resync failed: ${error.message}`);
}

async function runWithConcurrency<T>(items: T[], limit: number, worker: (item: T) => Promise<void>) {
  let index = 0;
  async function next(): Promise<void> {
    const i = index++;
    if (i >= items.length) return;
    await worker(items[i]);
    return next();
  }
  const runners = Array.from({ length: Math.min(limit, items.length) }, () => next());
  await Promise.all(runners);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (TRIGGER_SECRET) {
    const auth = req.headers.get("Authorization") ?? "";
    if (auth !== `Bearer ${TRIGGER_SECRET}`) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  }

  let body: any = {};
  try {
    body = await req.json();
  } catch {
    // empty body is fine, defaults to "daily"
  }

  const mode = body.mode ?? "daily";
  let startDate: Date;
  let endDate: Date;

  const today = new Date();
  today.setUTCHours(0, 0, 0, 0);

  if (mode === "daily") {
    startDate = addDays(today, -1);
    endDate = addDays(today, -1);
  } else if (mode === "backfill") {
    const days = Number(body.days ?? 30);
    startDate = addDays(today, -days);
    endDate = addDays(today, -1);
  } else if (mode === "custom") {
    if (!body.start_date || !body.end_date) {
      return new Response(JSON.stringify({ error: "custom mode needs start_date and end_date" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    startDate = new Date(body.start_date);
    endDate = new Date(body.end_date);
  } else {
    return new Response(JSON.stringify({ error: `unknown mode: ${mode}` }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const deleteBeforeSync = body.delete_before_sync === true;

  let companyQuery = supabase.from("zenoti_companies").select("*").eq("active", true);
  if (body.company_slug) companyQuery = companyQuery.eq("slug", body.company_slug);
  const { data: companies, error: companyErr } = await companyQuery;
  if (companyErr) {
    return new Response(JSON.stringify({ error: companyErr.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const allPairs: Array<{ company: any; center: any }> = [];
  for (const company of companies ?? []) {
    const { data: centers, error: centerErr } = await supabase
      .from("zenoti_centers")
      .select("*")
      .eq("company_slug", company.slug)
      .eq("active", true);
    if (centerErr) continue;

    for (const center of centers ?? []) {
      if (Array.isArray(body.center_ids) && body.center_ids.length > 0) {
        const wanted = body.center_ids.map((c: string) => c.toLowerCase());
        if (!wanted.includes(String(center.center_id).toLowerCase())) continue;
      }
      allPairs.push({ company, center });
    }
  }

  const CENTERS_PER_INVOCATION = Number(body.centers_per_call ?? 6);
  const toProcess = allPairs.slice(0, CENTERS_PER_INVOCATION);
  const remaining = allPairs.slice(CENTERS_PER_INVOCATION);

  const results: any[] = [];
  const centerTasks: Array<{ company: any; center: any; logId: any }> = [];

  for (const { company, center } of toProcess) {
    const { data: logRow } = await supabase
      .from("zenoti_sync_logs")
      .insert({
        company_slug: company.slug,
        center_id: center.center_id,
        start_date: fmt(startDate),
        end_date: fmt(endDate),
        status: "running",
      })
      .select()
      .single();

    centerTasks.push({ company, center, logId: logRow?.id });
  }

  const CONCURRENCY = 2;
  await runWithConcurrency(centerTasks, CONCURRENCY, async ({ company, center, logId }) => {
    let totalRows = 0;
    let deletedRows: number | null = null;
    try {
      if (deleteBeforeSync) {
        await deleteExistingRows(company.slug, center.center_id, startDate, endDate);
        deletedRows = 1; // marker that delete ran; exact count not returned by delete()
      }
      for (const chunk of chunkDateRange(startDate, endDate)) {
        const sales = await fetchSalesReport(company.api_key, center.center_id, chunk.start, chunk.end);
        if (sales.length) {
          const mapped = sales.map((r: any) => mapRow(company.slug, center.center_id, r));
          totalRows += await upsertRows(mapped);
        }
      }
      await supabase
        .from("zenoti_sync_logs")
        .update({ status: "success", rows_synced: totalRows, finished_at: new Date().toISOString() })
        .eq("id", logId);
      results.push({
        company: company.slug,
        center: center.center_id,
        rows: totalRows,
        ...(deletedRows !== null ? { deleted_before_sync: true } : {}),
      });
    } catch (e) {
      await supabase
        .from("zenoti_sync_logs")
        .update({ status: "error", error_message: String(e), finished_at: new Date().toISOString() })
        .eq("id", logId);
      results.push({ company: company.slug, center: center.center_id, error: String(e) });
    }
  });

  const response: any = { mode, start_date: fmt(startDate), end_date: fmt(endDate), results };

  if (remaining.length > 0) {
    response.pending_center_ids = remaining.map((p) => p.center.center_id);
    response.next_request = {
      ...(mode === "custom"
        ? { mode: "custom", start_date: fmt(startDate), end_date: fmt(endDate) }
        : mode === "backfill"
        ? { mode: "backfill", days: Number(body.days ?? 30) }
        : { mode: "daily" }),
      ...(body.centers_per_call ? { centers_per_call: body.centers_per_call } : {}),
      ...(deleteBeforeSync ? { delete_before_sync: true } : {}),
      ...(body.company_slug ? { company_slug: body.company_slug } : {}),
      center_ids: response.pending_center_ids,
    };
    response.note = `${remaining.length} center(s) not processed yet this call — send the "next_request" body above to continue.`;
  }

  return new Response(JSON.stringify(response, null, 2), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
