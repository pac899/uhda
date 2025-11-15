-- Supabase full schema for uhdav2
-- Creates tables, indexes, and RLS policies aligned with local SQLite schema
-- Assumptions:
-- - Single-tenant app using anon key. Policies allow full access for anon role.
-- - Primary keys are UUID on server; local SQLite keeps integer ids and stores server UUID in remote_id.
-- - Timestamps use timestamptz with default now().

-- Extensions
create extension if not exists pgcrypto; -- for gen_random_uuid()

-- Helper: uniform timestamp default
create or replace function now_utc() returns timestamptz language sql stable as $$ select now() at time zone 'utc' $$;

-- =========================
-- Core reference: products
-- =========================
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('sizes','weight','piece','mix')),
  name text not null,
  qr text,
  price_sell double precision,
  price_buy double precision,
  stock_qty double precision,
  min_qty double precision,
  main_image_url text,
  description text,
  usage_for text,
  recipe_text text,
  created_at timestamptz not null default now_utc(),
  updated_at timestamptz not null default now_utc(),
  deleted boolean not null default false,
  deleted_at timestamptz
);
-- helpful indexes
create index if not exists idx_products_updated_at on public.products(updated_at);
drop index if exists public.uniq_products_qr;
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'products_qr_key'
      and conrelid = 'public.products'::regclass
  ) then
    alter table public.products add constraint products_qr_key unique (qr);
  end if;
end $$;

create table if not exists public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  size text not null,
  price_sell double precision,
  price_buy double precision,
  stock_qty double precision
);
create index if not exists idx_product_variants_product on public.product_variants(product_id);

create table if not exists public.product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  url text,
  storage_path text,
  is_main boolean not null default false
);
create index if not exists idx_product_images_product on public.product_images(product_id);
create index if not exists idx_product_images_main on public.product_images(product_id, is_main);

-- =========================
-- Mix links (link mix product to existing products)
-- =========================
create table if not exists public.product_mix_links (
  id uuid primary key default gen_random_uuid(),
  mix_product_id uuid not null references public.products(id) on delete cascade,
  linked_product_id uuid not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now_utc()
);
create index if not exists idx_mix_links_mix on public.product_mix_links(mix_product_id);
create index if not exists idx_mix_links_linked on public.product_mix_links(linked_product_id);

-- Safe migration for existing deployments
alter table public.product_images add column if not exists storage_path text;
alter table public.products add column if not exists description text;
alter table public.products add column if not exists usage_for text;
alter table public.products add column if not exists recipe_text text;

-- =========================
-- Purchases and items
-- =========================
create table if not exists public.purchases (
  id uuid primary key default gen_random_uuid(),
  invoice_ref text,
  invoice_image_url text,
  edited boolean not null default false,
  updated_at timestamptz,
  created_at timestamptz not null default now_utc()
);

create table if not exists public.purchase_items (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.purchases(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  variant_id uuid references public.product_variants(id) on delete set null,
  qty double precision not null,
  unit_price_buy double precision not null,
  remaining_qty double precision,
  created_at timestamptz not null default now_utc()
);
create index if not exists idx_purchase_items_purchase on public.purchase_items(purchase_id);
create index if not exists idx_purchase_items_product on public.purchase_items(product_id);
create index if not exists idx_purchase_items_variant on public.purchase_items(variant_id);

-- =========================
-- Customers (moved earlier to satisfy FKs)
-- =========================
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  address text,
  building_code text,
  created_at timestamptz not null default now_utc(),
  updated_at timestamptz not null default now_utc()
);
create index if not exists idx_customers_phone on public.customers(phone);

-- =========================
-- Cash ledger
-- =========================
create table if not exists public.cash_ledger (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('income','withdrawal','purchase','sale')),
  amount double precision not null,
  note text,
  source_type text,
  source_id uuid,
  state integer,
  customer_id uuid references public.customers(id) on delete set null,
  created_at timestamptz not null default now_utc(),
  updated_at timestamptz,
  edited boolean default false,
  deleted boolean default false,
  prev_amount double precision,
  prev_note text,
  deleted_at timestamptz,
  currency_code text,
  rate_to_usd double precision,
  amount_currency double precision,
  usd_amount double precision
);
create index if not exists idx_cash_ledger_customer on public.cash_ledger(customer_id);
create index if not exists idx_cash_ledger_source on public.cash_ledger(source_type, source_id);

-- =========================
-- Sales: invoices and items
-- =========================
create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now_utc(),
  updated_at timestamptz,
  total_amount double precision not null,
  note text,
  title text,
  is_archived boolean not null default false,
  edited boolean not null default false,
  prev_snapshot jsonb,
  deleted boolean not null default false,
  deleted_at timestamptz,
  customer_id uuid references public.customers(id) on delete set null,
  currency_code text,
  rate_to_usd double precision
);
create index if not exists idx_invoices_customer on public.invoices(customer_id);

-- Idempotency key and server-managed timestamp
alter table public.invoices add column if not exists client_key text;
alter table public.invoices add column if not exists server_updated_at timestamptz not null default now_utc();
create unique index if not exists uniq_invoices_client_key on public.invoices(client_key);
create index if not exists idx_invoices_server_updated_at on public.invoices(server_updated_at);
create index if not exists idx_invoices_updated_at on public.invoices(updated_at);

-- Trigger to always bump server_updated_at on insert/update
create or replace function public.set_server_updated_at() returns trigger language plpgsql as $$
begin
  new.server_updated_at := now_utc();
  return new;
end$$;
drop trigger if exists trg_invoices_server_updated_at on public.invoices;
create trigger trg_invoices_server_updated_at
before insert or update on public.invoices
for each row execute function public.set_server_updated_at();

create table if not exists public.invoice_items (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  variant_id uuid references public.product_variants(id) on delete set null,
  qty double precision not null,
  unit_price double precision not null,
  subtotal double precision,
  created_at timestamptz not null default now_utc(),
  product_name text
);
create index if not exists idx_invoice_items_invoice on public.invoice_items(invoice_id);
create index if not exists idx_invoice_items_product on public.invoice_items(product_id);
create index if not exists idx_invoice_items_variant on public.invoice_items(variant_id);

-- =========================
-- Stock movements
-- =========================
create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now_utc(),
  product_id uuid not null references public.products(id) on delete cascade,
  qty double precision not null,
  type text not null check (type in ('sale','return')),
  note text,
  invoice_id uuid references public.invoices(id) on delete set null,
  purchase_id uuid references public.purchases(id) on delete set null
);
create index if not exists idx_stock_movements_product on public.stock_movements(product_id);
create index if not exists idx_stock_movements_invoice on public.stock_movements(invoice_id);
create index if not exists idx_stock_movements_purchase on public.stock_movements(purchase_id);

-- =========================
-- Offers
-- =========================
create table if not exists public.offers (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  variant_id uuid references public.product_variants(id) on delete set null,
  qty double precision not null,
  discount_type text not null check (discount_type in ('percent','fixed')),
  discount_value double precision not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  active boolean not null default true,
  deleted boolean not null default false,
  created_at timestamptz not null default now_utc(),
  updated_at timestamptz
);
create index if not exists idx_offers_product on public.offers(product_id);
create index if not exists idx_offers_variant on public.offers(variant_id);

-- =========================
-- Debts and payments
-- =========================
create table if not exists public.debts (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  total_amount double precision not null,
  paid_amount double precision not null default 0,
  currency text not null default 'USD',
  billing_period_start timestamptz,
  billing_period_end timestamptz,
  due_date timestamptz,
  is_recurring boolean not null default false,
  document_image_url text,
  recurrence_frequency text,
  created_at timestamptz not null default now_utc(),
  updated_at timestamptz
);
create index if not exists idx_debts_due on public.debts(due_date);

create table if not exists public.debt_payments (
  id uuid primary key default gen_random_uuid(),
  debt_id uuid not null references public.debts(id) on delete cascade,
  amount double precision not null,
  payment_date timestamptz not null default now_utc(),
  notes text,
  created_at timestamptz not null default now_utc(),
  updated_at timestamptz,
  currency_code text,
  rate_to_usd double precision,
  usd_amount double precision,
  amount_in_debt double precision
);

-- Merge documents into debt_payments: add columns for remote document info
alter table public.debt_payments add column if not exists document_url text;
alter table public.debt_payments add column if not exists document_storage_path text;

-- One-time backfill (only if legacy table exists)
DO $$
BEGIN
  IF to_regclass('public.debt_documents') IS NOT NULL THEN
    WITH first_doc AS (
      SELECT DISTINCT ON (debt_id) debt_id, url
      FROM public.debt_documents
      WHERE url IS NOT NULL AND url <> ''
      ORDER BY debt_id, created_at ASC
    )
    UPDATE public.debt_payments p
    SET document_url = fd.url
    FROM first_doc fd
    WHERE p.document_url IS NULL AND fd.debt_id = p.debt_id;
  END IF;
END $$;

-- (legacy debt_documents table intentionally not created anymore)

-- =========================
-- Notifications (low stock, etc.)
-- =========================
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete cascade,
  type text not null,
  message text not null,
  created_at timestamptz not null default now_utc(),
  read boolean not null default false
);
create index if not exists idx_notifications_product on public.notifications(product_id);

-- =========================
-- Currency rates (used by realtime in settings)
-- =========================
create table if not exists public.currency_rates (
  code text primary key,
  rate double precision not null,
  updated_at timestamptz not null default now_utc()
);

-- =========================
-- Store info (optional metadata)
-- =========================
create table if not exists public.store_info (
  id uuid primary key default gen_random_uuid(),
  name text,
  phone text,
  address text,
  logo_url text,
  supabase_url text,
  supabase_api_key text,
  currency_rates jsonb,
  backup_path text,
  created_at timestamptz not null default now_utc()
);

-- =========================
-- RLS: enable and allow anon full access (single-tenant)
-- =========================
alter table public.products enable row level security;
alter table public.product_variants enable row level security;
alter table public.product_images enable row level security;
alter table public.product_mix_links enable row level security;
alter table public.purchases enable row level security;
alter table public.purchase_items enable row level security;
alter table public.cash_ledger enable row level security;
alter table public.customers enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.stock_movements enable row level security;
alter table public.offers enable row level security;
alter table public.debts enable row level security;
alter table public.debt_payments enable row level security;
alter table if exists public.debt_documents enable row level security;
alter table public.notifications enable row level security;
alter table public.currency_rates enable row level security;
alter table public.store_info enable row level security;

-- Simple allow-all policies for anon (adjust later for multi-tenant)
-- products
drop policy if exists anon_select on public.products;
drop policy if exists anon_modify on public.products;
create policy anon_select on public.products for select using (true);
create policy anon_modify on public.products for all using (true) with check (true);

-- product_variants
drop policy if exists anon_select on public.product_variants;
drop policy if exists anon_modify on public.product_variants;
create policy anon_select on public.product_variants for select using (true);
create policy anon_modify on public.product_variants for all using (true) with check (true);

-- product_images
drop policy if exists anon_select on public.product_images;
drop policy if exists anon_modify on public.product_images;
create policy anon_select on public.product_images for select using (true);
create policy anon_modify on public.product_images for all using (true) with check (true);

-- product_mix_links
drop policy if exists anon_select on public.product_mix_links;
drop policy if exists anon_modify on public.product_mix_links;
create policy anon_select on public.product_mix_links for select using (true);
create policy anon_modify on public.product_mix_links for all using (true) with check (true);

-- purchases
drop policy if exists anon_select on public.purchases;
drop policy if exists anon_modify on public.purchases;
create policy anon_select on public.purchases for select using (true);
create policy anon_modify on public.purchases for all using (true) with check (true);

-- purchase_items
drop policy if exists anon_select on public.purchase_items;
drop policy if exists anon_modify on public.purchase_items;
create policy anon_select on public.purchase_items for select using (true);
create policy anon_modify on public.purchase_items for all using (true) with check (true);

-- cash_ledger
drop policy if exists anon_select on public.cash_ledger;
drop policy if exists anon_modify on public.cash_ledger;
create policy anon_select on public.cash_ledger for select using (true);
create policy anon_modify on public.cash_ledger for all using (true) with check (true);

-- customers
drop policy if exists anon_select on public.customers;
drop policy if exists anon_modify on public.customers;
create policy anon_select on public.customers for select using (true);
create policy anon_modify on public.customers for all using (true) with check (true);

-- invoices
drop policy if exists anon_select on public.invoices;
drop policy if exists anon_modify on public.invoices;
create policy anon_select on public.invoices for select using (true);
create policy anon_modify on public.invoices for all using (true) with check (true);

-- invoice_items
drop policy if exists anon_select on public.invoice_items;
drop policy if exists anon_modify on public.invoice_items;
create policy anon_select on public.invoice_items for select using (true);
create policy anon_modify on public.invoice_items for all using (true) with check (true);

-- stock_movements
drop policy if exists anon_select on public.stock_movements;
drop policy if exists anon_modify on public.stock_movements;
create policy anon_select on public.stock_movements for select using (true);
create policy anon_modify on public.stock_movements for all using (true) with check (true);

-- offers
drop policy if exists anon_select on public.offers;
drop policy if exists anon_modify on public.offers;
create policy anon_select on public.offers for select using (true);
create policy anon_modify on public.offers for all using (true) with check (true);

-- debts
drop policy if exists anon_select on public.debts;
drop policy if exists anon_modify on public.debts;
create policy anon_select on public.debts for select using (true);
create policy anon_modify on public.debts for all using (true) with check (true);

-- debt_payments
drop policy if exists anon_select on public.debt_payments;
drop policy if exists anon_modify on public.debt_payments;
create policy anon_select on public.debt_payments for select using (true);
create policy anon_modify on public.debt_payments for all using (true) with check (true);

-- (no policies for legacy debt_documents; table will be dropped if exists)

-- Deprecate debt_documents: table is no longer needed after merging into debt_payments
-- Safe to drop after backfill. Keep selects/clients tolerant by using left joins in app if needed.
drop table if exists public.debt_documents cascade;

-- notifications
drop policy if exists anon_select on public.notifications;
drop policy if exists anon_modify on public.notifications;
create policy anon_select on public.notifications for select using (true);
create policy anon_modify on public.notifications for all using (true) with check (true);

-- currency_rates
drop policy if exists anon_select on public.currency_rates;
drop policy if exists anon_modify on public.currency_rates;
create policy anon_select on public.currency_rates for select using (true);
create policy anon_modify on public.currency_rates for all using (true) with check (true);

-- store_info
drop policy if exists anon_select on public.store_info;
drop policy if exists anon_modify on public.store_info;
create policy anon_select on public.store_info for select using (true);
create policy anon_modify on public.store_info for all using (true) with check (true);

-- =========================
-- Storage bucket and policies (public)
-- =========================
-- Create bucket for product images and documents
insert into storage.buckets (id, name, public) values ('public','public', true)
  on conflict (id) do update set public = excluded.public;

-- RLS on storage.objects
drop policy if exists anon_read_storage on storage.objects;
drop policy if exists anon_write_storage on storage.objects;
drop policy if exists anon_update_storage on storage.objects;
drop policy if exists anon_delete_storage on storage.objects;
create policy anon_read_storage on storage.objects for select using (bucket_id = 'public');
create policy anon_write_storage on storage.objects for insert with check (bucket_id = 'public');
create policy anon_update_storage on storage.objects for update using (bucket_id = 'public') with check (bucket_id = 'public');
create policy anon_delete_storage on storage.objects for delete using (bucket_id = 'public');

create or replace function public.dedup_products() returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  with ranked as (
    select id, name, stock_qty, price_sell, price_buy, created_at,
           row_number() over(partition by name, stock_qty, price_sell, price_buy order by created_at asc, id asc) as rn,
           first_value(id) over(partition by name, stock_qty, price_sell, price_buy order by created_at asc, id asc) as keep_id
    from public.products
  ), dups as (
    select id as dup_id, keep_id from ranked where rn > 1
  ), u_variants as (
    update public.product_variants pv set product_id = d.keep_id from dups d where pv.product_id = d.dup_id returning 1
  ), u_images as (
    update public.product_images pi set product_id = d.keep_id from dups d where pi.product_id = d.dup_id returning 1
  ), u_mix1 as (
    update public.product_mix_links ml set mix_product_id = d.keep_id from dups d where ml.mix_product_id = d.dup_id returning 1
  ), u_mix2 as (
    update public.product_mix_links ml set linked_product_id = d.keep_id from dups d where ml.linked_product_id = d.dup_id returning 1
  ), u_purchase_items as (
    update public.purchase_items it set product_id = d.keep_id from dups d where it.product_id = d.dup_id returning 1
  ), u_invoice_items as (
    update public.invoice_items it set product_id = d.keep_id from dups d where it.product_id = d.dup_id returning 1
  ), u_stock_movements as (
    update public.stock_movements sm set product_id = d.keep_id from dups d where sm.product_id = d.dup_id returning 1
  ), u_offers as (
    update public.offers o set product_id = d.keep_id from dups d where o.product_id = d.dup_id returning 1
  ), u_notifications as (
    update public.notifications n set product_id = d.keep_id from dups d where n.product_id = d.dup_id returning 1
  ), del as (
    delete from public.products p using dups d where p.id = d.dup_id returning 1
  ), cnt as (
    select count(*) as c from dups
  )
  select c into v_count from cnt;
  return coalesce(v_count, 0);
end$$;

create or replace function public.trg_products_dedup() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.dedup_products();
  return new;
end$$;

drop trigger if exists products_dedup_trigger on public.products;
create trigger products_dedup_trigger
after insert or update on public.products
for each statement execute function public.trg_products_dedup();

create extension if not exists pg_cron;
do $$
begin
  if not exists (select 1 from cron.job where jobname = 'dedup_products_hourly') then
    perform cron.schedule('dedup_products_hourly', '0 * * * *', 'select public.dedup_products()');
  end if;
end $$;
