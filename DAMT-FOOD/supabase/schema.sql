-- =============================================================================
-- DAMT Food - hardened schema. Run ONCE on a fresh Supabase project
-- (SQL Editor -> New query -> paste -> Run).
-- Clients (Android apps) never write orders, payments, OTPs or roles directly.
-- Those writes happen only in Edge Functions using the service role.
-- =============================================================================

create extension if not exists pgcrypto;

create type user_role      as enum ('customer', 'admin', 'delivery_partner');
create type order_status   as enum ('PENDING','CONFIRMED','PREPARING','PACKED','ASSIGNED',
                                    'OUT_FOR_DELIVERY','DELIVERED','CANCELLED',
                                    'PAYMENT_FAILED','REFUND_PENDING','REFUNDED');
create type payment_method as enum ('UPI','COD','WALLET');
create type payment_status as enum ('PENDING','SUCCESS','FAILED','REFUNDED');

-- ------------------------------------------------------------------ profiles
create table profiles (
  id                  uuid primary key references auth.users on delete cascade,
  full_name           text,
  email               text,
  username            text unique,
  mobile_number       text unique check (mobile_number ~ '^[6-9][0-9]{9}$'),
  role                user_role not null default 'customer',
  is_verified         boolean not null default false,
  is_active           boolean not null default true,
  created_by_admin_id uuid references profiles(id),
  wallet_balance      numeric(12,2) not null default 0 check (wallet_balance >= 0),
  loyalty_points      integer not null default 0 check (loyalty_points >= 0),
  avatar_url          text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Role helpers. app_role() is NULL for disabled users, and for delivery
-- partners whose parent admin is disabled -> they lose all access at once.
create function public.app_role() returns user_role
language sql stable security definer set search_path = public as $$
  select p.role from profiles p
  where p.id = auth.uid() and p.is_active
    and (p.role <> 'delivery_partner' or exists (
          select 1 from profiles a
          where a.id = p.created_by_admin_id and a.role = 'admin' and a.is_active))
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.app_role() = 'admin', false)
$$;

-- Every new auth user gets a profile (always a customer; roles are set only by
-- the service role). Staff accounts use <username>@staff.damtfood.app.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name, email, username)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
          new.email,
          case when new.email like '%@staff.damtfood.app' then split_part(new.email,'@',1) end);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Stops users from editing role / verification / wallet etc. from the client.
create function public.protect_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then            -- service role / SQL editor
    new.updated_at := now(); return new;
  end if;
  if public.is_admin() then
    if new.is_active is distinct from old.is_active then
      insert into audit_logs(admin_id, action, table_name, record_id, old_value, new_value)
      values (auth.uid(), 'PROFILE_ACTIVE_CHANGED', 'profiles', old.id,
              jsonb_build_object('is_active', old.is_active),
              jsonb_build_object('is_active', new.is_active));
    end if;
    new.role := old.role; new.mobile_number := old.mobile_number;
    new.is_verified := old.is_verified; new.wallet_balance := old.wallet_balance;
    new.loyalty_points := old.loyalty_points; new.created_by_admin_id := old.created_by_admin_id;
  else
    new.role := old.role; new.is_verified := old.is_verified; new.is_active := old.is_active;
    new.mobile_number := old.mobile_number; new.wallet_balance := old.wallet_balance;
    new.loyalty_points := old.loyalty_points; new.created_by_admin_id := old.created_by_admin_id;
    new.username := old.username; new.email := old.email;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger protect_profile_cols before update on profiles
  for each row execute function public.protect_profile();

-- ------------------------------------------------------------------- catalog
create table categories (
  id uuid primary key default gen_random_uuid(),
  name text not null, description text, image_url text,
  is_active boolean not null default true, sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create table products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references categories(id) on delete set null,
  name text not null, description text,
  base_price numeric(12,2) not null check (base_price >= 0),
  image_url text, is_active boolean not null default true, is_featured boolean not null default false,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  variant_name text not null,
  price_modifier numeric(12,2) not null default 0,
  stock_quantity integer not null default 0 check (stock_quantity >= 0),
  min_stock_level integer not null default 5,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------- addresses
create table addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  label text, address_line_1 text not null, address_line_2 text,
  city text, state text, pincode text,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------------ settings
create table store_settings (key text primary key, value jsonb not null);
insert into store_settings(key, value) values
  ('store_lat', '0'),               -- SET THESE to your shop location
  ('store_lng', '0'),
  ('max_delivery_km', '12'),
  ('free_delivery_above', '500'),
  ('cod_max', '3000');

create table delivery_pricing (
  id uuid primary key default gen_random_uuid(),
  min_km numeric(5,2) not null, max_km numeric(5,2) not null, fee numeric(12,2) not null,
  created_at timestamptz not null default now(),
  check (max_km > min_km)
);
insert into delivery_pricing(min_km, max_km, fee) values (0,2,20),(2,5,35),(5,8,50),(8,12,70);

-- -------------------------------------------------------------------- orders
create table orders (
  id uuid primary key default gen_random_uuid(),
  order_number bigint generated by default as identity unique,
  customer_id uuid not null references profiles(id),
  delivery_partner_id uuid references profiles(id),
  address_id uuid references addresses(id),
  address_snapshot jsonb not null,
  distance_km numeric(6,2),
  total_amount numeric(12,2) not null,
  delivery_fee numeric(12,2) not null,
  discount_amount numeric(12,2) not null default 0,
  final_amount numeric(12,2) not null,
  coupon_code text,
  payment_method payment_method not null,
  payment_status payment_status not null default 'PENDING',
  order_status order_status not null default 'PENDING',
  cancel_reason text,
  idempotency_key text not null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (customer_id, idempotency_key)
);
create table order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  product_id uuid references products(id), variant_id uuid references product_variants(id),
  product_name text not null, variant_name text,
  quantity integer not null check (quantity > 0),
  unit_price numeric(12,2) not null, subtotal numeric(12,2) not null,
  special_instructions text
);
create table order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  status order_status not null, changed_by uuid references profiles(id), notes text,
  created_at timestamptz not null default now()
);

-- OTP tables: no policies at all = reachable only with the service role.
create table otp_requests (
  user_id uuid primary key references profiles(id) on delete cascade,
  mobile text not null, otp_hash text not null,
  expires_at timestamptz not null, attempts integer not null default 0,
  last_sent_at timestamptz not null default now()
);
create table delivery_otps (
  order_id uuid primary key references orders(id) on delete cascade,
  otp_hash text not null, expires_at timestamptz not null, attempts integer not null default 0,
  created_at timestamptz not null default now()
);

create table payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id),
  method payment_method not null, amount numeric(12,2) not null,
  status payment_status not null, gateway_ref text unique, raw jsonb,
  created_at timestamptz not null default now()
);
create table cod_collections (
  order_id uuid primary key references orders(id),
  partner_id uuid not null references profiles(id),
  amount numeric(12,2) not null, collected_at timestamptz not null default now(),
  settled boolean not null default false, settled_at timestamptz, settled_by uuid references profiles(id)
);
create table delivery_proofs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id),
  partner_id uuid not null references profiles(id),
  storage_path text not null, created_at timestamptz not null default now()
);

-- ------------------------------------------------------------ other business
create table coupons (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  discount_type text not null check (discount_type in ('PERCENT','FLAT')),
  discount_value numeric(12,2) not null check (discount_value > 0),
  min_order_value numeric(12,2) not null default 0, max_discount numeric(12,2),
  expiry_date timestamptz not null, usage_limit integer, used_count integer not null default 0,
  is_active boolean not null default true, created_at timestamptz not null default now()
);
create table wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id),
  amount numeric(12,2) not null, transaction_type text not null check (transaction_type in ('CREDIT','DEBIT')),
  reference_id uuid, description text, created_at timestamptz not null default now()
);
create table reviews (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id),
  product_id uuid references products(id),
  order_id uuid not null references orders(id),
  rating integer not null check (rating between 1 and 5), comment text,
  created_at timestamptz not null default now(),
  unique (user_id, order_id, product_id)
);
create table notification_log (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references orders(id), user_id uuid references profiles(id),
  channel text not null check (channel in ('WHATSAPP','TELEGRAM','PUSH')),
  event text not null, status text not null default 'PENDING' check (status in ('PENDING','SENT','FAILED')),
  error text, created_at timestamptz not null default now(),
  unique (order_id, event, channel)        -- one message per order/event/channel
);
create table audit_logs (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid references profiles(id), action text not null, table_name text,
  record_id uuid, old_value jsonb, new_value jsonb, created_at timestamptz not null default now()
);
create table support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id),
  subject text not null, description text not null,
  status text not null default 'OPEN' check (status in ('OPEN','IN_PROGRESS','RESOLVED','CLOSED')),
  priority text not null default 'MEDIUM' check (priority in ('LOW','MEDIUM','HIGH')),
  last_updated timestamptz not null default now(), created_at timestamptz not null default now()
);

create index on orders(order_status);
create index on orders(customer_id);
create index on orders(delivery_partner_id);
create index on order_items(order_id);
create index on products(category_id);
create index on product_variants(product_id);
create index on order_status_history(order_id);

-- ================================================================== functions
-- Atomic order placement: re-prices every item from the DB, locks stock,
-- applies coupon, checks COD limit and free-delivery threshold. Idempotent.
create function public.place_order(
  p_customer uuid, p_address uuid, p_method payment_method, p_items jsonb,
  p_fee numeric, p_distance numeric, p_coupon text, p_idem text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_order uuid; v_total numeric(12,2) := 0; v_disc numeric(12,2) := 0; v_fee numeric(12,2) := p_fee;
  v_final numeric(12,2); v_addr addresses%rowtype; v_item record; v_var record; v_cpn coupons%rowtype;
  v_sub numeric(12,2); v_free numeric; v_cod numeric;
begin
  select id into v_order from orders where customer_id = p_customer and idempotency_key = p_idem;
  if found then return v_order; end if;

  if p_method <> 'COD' then raise exception 'PAYMENT_METHOD_UNAVAILABLE'; end if;
  select * into v_addr from addresses where id = p_address and user_id = p_customer;
  if not found then raise exception 'ADDRESS_NOT_FOUND'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'EMPTY_CART'; end if;

  insert into orders(customer_id, address_id, address_snapshot, distance_km, total_amount,
                     delivery_fee, final_amount, payment_method, idempotency_key)
  values (p_customer, p_address, to_jsonb(v_addr), p_distance, 0, 0, 0, p_method, p_idem)
  returning id into v_order;

  for v_item in
    select (e->>'variant_id')::uuid as variant_id, (e->>'qty')::int as qty, e->>'note' as note
    from jsonb_array_elements(p_items) e
  loop
    if v_item.qty is null or v_item.qty < 1 or v_item.qty > 50 then raise exception 'BAD_QUANTITY'; end if;
    select v.id as vid, v.variant_name, v.price_modifier, v.stock_quantity,
           p.id as pid, p.name as pname, p.base_price
      into v_var
      from product_variants v join products p on p.id = v.product_id
     where v.id = v_item.variant_id and v.is_active and p.is_active
       for update of v;
    if not found then raise exception 'ITEM_UNAVAILABLE'; end if;
    if v_var.stock_quantity < v_item.qty then raise exception 'OUT_OF_STOCK: %', v_var.pname; end if;
    update product_variants set stock_quantity = stock_quantity - v_item.qty where id = v_var.vid;
    v_sub := (v_var.base_price + v_var.price_modifier) * v_item.qty;
    insert into order_items(order_id, product_id, variant_id, product_name, variant_name,
                            quantity, unit_price, subtotal, special_instructions)
    values (v_order, v_var.pid, v_var.vid, v_var.pname, v_var.variant_name, v_item.qty,
            v_var.base_price + v_var.price_modifier, v_sub, left(v_item.note, 300));
    v_total := v_total + v_sub;
  end loop;

  if coalesce(p_coupon, '') <> '' then
    select * into v_cpn from coupons
     where upper(code) = upper(p_coupon) and is_active and expiry_date > now()
       and (usage_limit is null or used_count < usage_limit) and v_total >= min_order_value
       for update;
    if not found then raise exception 'COUPON_INVALID'; end if;
    v_disc := case when v_cpn.discount_type = 'PERCENT'
                   then round(v_total * v_cpn.discount_value / 100, 2) else v_cpn.discount_value end;
    if v_cpn.max_discount is not null then v_disc := least(v_disc, v_cpn.max_discount); end if;
    v_disc := least(v_disc, v_total);
    update coupons set used_count = used_count + 1 where id = v_cpn.id;
  end if;

  select (value #>> '{}')::numeric into v_free from store_settings where key = 'free_delivery_above';
  if v_free is not null and v_free > 0 and v_total >= v_free then v_fee := 0; end if;

  v_final := v_total - v_disc + v_fee;
  select (value #>> '{}')::numeric into v_cod from store_settings where key = 'cod_max';
  if p_method = 'COD' and v_cod is not null and v_final > v_cod then raise exception 'COD_LIMIT: %', v_cod; end if;

  update orders set total_amount = v_total, delivery_fee = v_fee, discount_amount = v_disc,
         final_amount = v_final, coupon_code = nullif(p_coupon, '') where id = v_order;
  insert into order_status_history(order_id, status, changed_by, notes)
  values (v_order, 'PENDING', p_customer, 'Order placed');
  return v_order;
end $$;

create function public.restock_order(p_order uuid) returns void
language sql security definer set search_path = public as $$
  update product_variants v set stock_quantity = v.stock_quantity + i.quantity
  from order_items i where i.order_id = p_order and i.variant_id = v.id
$$;

-- OTP helpers (atomic, so double taps and parallel guesses cannot bypass limits)
create function public.issue_otp(p_user uuid, p_mobile text, p_hash text) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into otp_requests(user_id, mobile, otp_hash, expires_at, attempts, last_sent_at)
  values (p_user, p_mobile, p_hash, now() + interval '5 minutes', 0, now())
  on conflict (user_id) do update
     set mobile = excluded.mobile, otp_hash = excluded.otp_hash, expires_at = excluded.expires_at,
         attempts = 0, last_sent_at = now()
   where otp_requests.last_sent_at < now() - interval '60 seconds';
  get diagnostics n = row_count;
  return n > 0;
end $$;

create function public.otp_attempt(p_user uuid) returns table(o_hash text, o_mobile text)
language sql security definer set search_path = public as $$
  update otp_requests set attempts = attempts + 1
   where user_id = p_user and attempts < 5 and expires_at > now()
  returning otp_hash, mobile
$$;

create function public.delivery_otp_attempt(p_order uuid) returns table(o_hash text)
language sql security definer set search_path = public as $$
  update delivery_otps set attempts = attempts + 1
   where order_id = p_order and attempts < 5 and expires_at > now()
  returning otp_hash
$$;

-- Delivery partners see ONLY the minimum for their own active deliveries.
create function public.delivery_orders() returns table(
  id uuid, order_number bigint, order_status order_status, customer_name text,
  customer_mobile text, address jsonb, cod_amount numeric, final_amount numeric, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_number, o.order_status, p.full_name, p.mobile_number, o.address_snapshot,
         case when o.payment_method = 'COD' and o.payment_status <> 'SUCCESS' then o.final_amount else 0 end,
         o.final_amount, o.created_at
    from orders o join profiles p on p.id = o.customer_id
   where public.app_role() = 'delivery_partner' and o.delivery_partner_id = auth.uid()
     and o.order_status in ('ASSIGNED','OUT_FOR_DELIVERY')
   order by o.created_at
$$;

-- Audit manual stock edits made from the admin app.
create function public.audit_stock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.stock_quantity is distinct from old.stock_quantity then
    insert into audit_logs(admin_id, action, table_name, record_id, old_value, new_value)
    values (auth.uid(), 'STOCK_UPDATE', 'product_variants', old.id,
            jsonb_build_object('stock', old.stock_quantity), jsonb_build_object('stock', new.stock_quantity));
  end if;
  return new;
end $$;
create trigger audit_variant_stock after update on product_variants
  for each row execute function public.audit_stock();

-- Sensitive functions: service role only.
revoke execute on function public.place_order(uuid,uuid,payment_method,jsonb,numeric,numeric,text,text) from public, anon, authenticated;
revoke execute on function public.restock_order(uuid)        from public, anon, authenticated;
revoke execute on function public.issue_otp(uuid,text,text)  from public, anon, authenticated;
revoke execute on function public.otp_attempt(uuid)          from public, anon, authenticated;
revoke execute on function public.delivery_otp_attempt(uuid) from public, anon, authenticated;
revoke execute on function public.handle_new_user()          from public, anon, authenticated;
revoke execute on function public.delivery_orders() from public, anon;
revoke execute on function public.app_role()        from public, anon;
revoke execute on function public.is_admin()        from public, anon;

-- ====================================================================== RLS
alter table profiles            enable row level security;
alter table categories          enable row level security;
alter table products            enable row level security;
alter table product_variants    enable row level security;
alter table addresses           enable row level security;
alter table store_settings      enable row level security;
alter table delivery_pricing    enable row level security;
alter table orders              enable row level security;
alter table order_items         enable row level security;
alter table order_status_history enable row level security;
alter table otp_requests        enable row level security;
alter table delivery_otps       enable row level security;
alter table payments            enable row level security;
alter table cod_collections     enable row level security;
alter table delivery_proofs     enable row level security;
alter table coupons             enable row level security;
alter table wallet_transactions enable row level security;
alter table reviews             enable row level security;
alter table notification_log    enable row level security;
alter table audit_logs          enable row level security;
alter table support_tickets     enable row level security;

create policy profiles_read   on profiles for select to authenticated using (id = auth.uid() or public.is_admin());
create policy profiles_update on profiles for update to authenticated
  using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());

create policy categories_read on categories for select to authenticated using (is_active or public.is_admin());
create policy categories_admin on categories for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy products_read on products for select to authenticated using (is_active or public.is_admin());
create policy products_admin on products for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy variants_read on product_variants for select to authenticated using (is_active or public.is_admin());
create policy variants_admin on product_variants for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy addresses_own on addresses for all to authenticated
  using (user_id = auth.uid() and public.app_role() = 'customer')
  with check (user_id = auth.uid() and public.app_role() = 'customer');
create policy addresses_admin_read on addresses for select to authenticated using (public.is_admin());

create policy settings_admin on store_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy pricing_read on delivery_pricing for select to authenticated using (true);
create policy pricing_admin on delivery_pricing for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy orders_customer on orders for select to authenticated
  using (customer_id = auth.uid() and public.app_role() = 'customer');
create policy orders_admin on orders for select to authenticated using (public.is_admin());

create policy items_customer on order_items for select to authenticated using (
  exists (select 1 from orders o where o.id = order_id and o.customer_id = auth.uid()));
create policy items_admin on order_items for select to authenticated using (public.is_admin());

create policy history_customer on order_status_history for select to authenticated using (
  exists (select 1 from orders o where o.id = order_id and o.customer_id = auth.uid()));
create policy history_admin on order_status_history for select to authenticated using (public.is_admin());

create policy payments_customer on payments for select to authenticated using (
  exists (select 1 from orders o where o.id = order_id and o.customer_id = auth.uid()));
create policy payments_admin on payments for select to authenticated using (public.is_admin());

create policy cod_partner on cod_collections for select to authenticated
  using (partner_id = auth.uid() and public.app_role() = 'delivery_partner');
create policy cod_admin on cod_collections for select to authenticated using (public.is_admin());
create policy proofs_admin on delivery_proofs for select to authenticated using (public.is_admin());
create policy proofs_partner on delivery_proofs for select to authenticated
  using (partner_id = auth.uid() and public.app_role() = 'delivery_partner');

create policy coupons_admin on coupons for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy wallet_own on wallet_transactions for select to authenticated using (user_id = auth.uid() or public.is_admin());

create policy reviews_read on reviews for select to authenticated using (true);
create policy reviews_insert on reviews for insert to authenticated with check (
  user_id = auth.uid() and exists (select 1 from orders o
    where o.id = order_id and o.customer_id = auth.uid() and o.order_status = 'DELIVERED'));

create policy notif_admin on notification_log for select to authenticated using (public.is_admin());
create policy audit_admin on audit_logs for select to authenticated using (public.is_admin());

create policy tickets_own_read on support_tickets for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy tickets_own_insert on support_tickets for insert to authenticated with check (user_id = auth.uid());
create policy tickets_admin_update on support_tickets for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- No access at all for logged-out visitors.
revoke all on all tables in schema public from anon;

-- ================================================================== storage
insert into storage.buckets(id, name, public) values
  ('product-images', 'product-images', true),
  ('delivery-proofs', 'delivery-proofs', false)
on conflict (id) do nothing;

drop policy if exists "product images public read" on storage.objects;
drop policy if exists "product images admin write" on storage.objects;
drop policy if exists "proofs partner upload" on storage.objects;
drop policy if exists "proofs admin read" on storage.objects;
create policy "product images public read" on storage.objects for select using (bucket_id = 'product-images');
create policy "product images admin write" on storage.objects for all to authenticated
  using (bucket_id = 'product-images' and public.is_admin())
  with check (bucket_id = 'product-images' and public.is_admin());
create policy "proofs partner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'delivery-proofs' and public.app_role() = 'delivery_partner'
              and (storage.foldername(name))[1] = auth.uid()::text);
create policy "proofs admin read" on storage.objects for select to authenticated
  using (bucket_id = 'delivery-proofs' and public.is_admin());
