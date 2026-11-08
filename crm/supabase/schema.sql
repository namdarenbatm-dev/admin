-- SNI CRM production database foundation
-- PostgreSQL / Supabase. Apply in Supabase SQL Editor after creating a project.
create extension if not exists pgcrypto;

do $$ begin
  create type public.app_role as enum ('super_admin','sales_manager','regional_manager','broker','bi_analyst','operations','viewer');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.record_status as enum ('draft','pending','active','suspended','rejected','archived');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.terminal_status as enum ('introduced','approved','allocated','pending_install','installed','active','suspended','returned');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.lead_stage as enum ('new','qualified','proposal','negotiation','won','lost');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  phone text,
  role public.app_role not null default 'viewer',
  region text,
  broker_id uuid,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.regions (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  code text unique,
  manager_id uuid references public.profiles(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.brokers (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  legal_name text not null,
  manager_name text,
  phone text,
  email text,
  region_id uuid references public.regions(id),
  address text,
  contract_start date,
  contract_end date,
  status public.record_status not null default 'pending',
  notes text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles drop constraint if exists profiles_broker_id_fkey;
alter table public.profiles add constraint profiles_broker_id_fkey foreign key (broker_id) references public.brokers(id) on delete set null;

create table if not exists public.merchants (
  id uuid primary key default gen_random_uuid(),
  merchant_code text not null unique,
  legal_name text not null,
  national_id text,
  economic_code text,
  category text,
  phone text,
  province text,
  city text,
  address text,
  status public.record_status not null default 'pending',
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.sales_points (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  broker_id uuid not null references public.brokers(id),
  region_id uuid references public.regions(id),
  manager_name text,
  phone text,
  monthly_target integer not null default 0 check (monthly_target >= 0),
  status public.record_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.terminals (
  id uuid primary key default gen_random_uuid(),
  terminal_code text not null unique,
  merchant_id uuid references public.merchants(id),
  sales_point_id uuid references public.sales_points(id),
  broker_id uuid references public.brokers(id),
  model text,
  serial_number text unique,
  lifecycle_status public.terminal_status not null default 'introduced',
  introduced_at timestamptz,
  approved_at timestamptz,
  allocated_at timestamptz,
  installed_at timestamptz,
  first_transaction_at timestamptz,
  last_transaction_at timestamptz,
  installation_deadline date,
  notes text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.terminal_status_history (
  id bigserial primary key,
  terminal_id uuid not null references public.terminals(id) on delete cascade,
  from_status public.terminal_status,
  to_status public.terminal_status not null,
  changed_by uuid references public.profiles(id),
  note text,
  changed_at timestamptz not null default now()
);

create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  merchant_name text,
  contact_name text,
  phone text,
  source text,
  broker_id uuid references public.brokers(id),
  region_id uuid references public.regions(id),
  stage public.lead_stage not null default 'new',
  estimated_terminals integer not null default 0 check (estimated_terminals >= 0),
  estimated_value numeric(18,2) not null default 0 check (estimated_value >= 0),
  expected_close_date date,
  lost_reason text,
  notes text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.targets (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  metric text not null check (metric in ('introductions','installations','active_terminals','transaction_count','transaction_amount','revenue')),
  period_start date not null,
  period_end date not null,
  target_value numeric(20,2) not null check (target_value >= 0),
  broker_id uuid references public.brokers(id),
  sales_point_id uuid references public.sales_points(id),
  region_id uuid references public.regions(id),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  check (period_end >= period_start)
);

create table if not exists public.commission_rules (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  metric text not null,
  rate numeric(12,4) not null default 0 check (rate >= 0),
  fixed_amount numeric(18,2) not null default 0 check (fixed_amount >= 0),
  effective_from date not null,
  effective_to date,
  is_active boolean not null default true,
  conditions jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);

create table if not exists public.commission_ledger (
  id uuid primary key default gen_random_uuid(),
  broker_id uuid not null references public.brokers(id),
  rule_id uuid references public.commission_rules(id),
  period_start date not null,
  period_end date not null,
  basis_value numeric(20,2) not null default 0,
  amount numeric(18,2) not null default 0,
  status text not null default 'calculated' check (status in ('calculated','approved','paid','reversed')),
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.daily_transaction_metrics (
  id uuid primary key default gen_random_uuid(),
  terminal_id uuid not null references public.terminals(id) on delete cascade,
  metric_date date not null,
  transaction_count bigint not null default 0 check (transaction_count >= 0),
  transaction_amount numeric(22,2) not null default 0 check (transaction_amount >= 0),
  fee_amount numeric(18,2) not null default 0 check (fee_amount >= 0),
  source text not null default 'manual',
  imported_at timestamptz not null default now(),
  unique (terminal_id, metric_date)
);

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  assigned_to uuid references public.profiles(id),
  broker_id uuid references public.brokers(id),
  terminal_id uuid references public.terminals(id),
  due_at timestamptz,
  priority text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  status text not null default 'open' check (status in ('open','in_progress','done','cancelled')),
  created_by uuid references public.profiles(id),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.workflow_rules (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  event_key text not null,
  conditions jsonb not null default '{}'::jsonb,
  action_key text not null,
  is_enabled boolean not null default false,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.audit_logs (
  id bigserial primary key,
  actor_id uuid references public.profiles(id),
  action text not null,
  entity text not null,
  entity_id text,
  before_data jsonb,
  after_data jsonb,
  ip_address inet,
  created_at timestamptz not null default now()
);

create index if not exists idx_terminals_broker_status on public.terminals(broker_id,lifecycle_status);
create index if not exists idx_terminals_merchant on public.terminals(merchant_id);
create index if not exists idx_transactions_date on public.daily_transaction_metrics(metric_date);
create index if not exists idx_transactions_terminal_date on public.daily_transaction_metrics(terminal_id,metric_date);
create index if not exists idx_tasks_assignee_status on public.tasks(assigned_to,status,due_at);
create index if not exists idx_leads_stage on public.leads(stage,expected_close_date);
create index if not exists idx_commission_broker_period on public.commission_ledger(broker_id,period_start,period_end);

create or replace function public.current_role()
returns public.app_role language sql stable security definer set search_path=public
as $$ select role from public.profiles where id=auth.uid() and is_active=true $$;

create or replace function public.can_manage()
returns boolean language sql stable security definer set search_path=public
as $$ select coalesce(public.current_role() in ('super_admin','sales_manager','regional_manager','operations'),false) $$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at=now(); return new; end $$;

do $$ declare t text; begin
  foreach t in array array['profiles','brokers','merchants','sales_points','terminals','leads','tasks'] loop
    execute format('drop trigger if exists %I_touch on public.%I',t,t);
    execute format('create trigger %I_touch before update on public.%I for each row execute function public.touch_updated_at()',t,t);
  end loop;
end $$;

create or replace function public.capture_terminal_status()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if tg_op='INSERT' then
    insert into public.terminal_status_history(terminal_id,from_status,to_status,changed_by,note)
    values(new.id,null,new.lifecycle_status,auth.uid(),'ایجاد پایانه');
  elsif old.lifecycle_status is distinct from new.lifecycle_status then
    insert into public.terminal_status_history(terminal_id,from_status,to_status,changed_by)
    values(new.id,old.lifecycle_status,new.lifecycle_status,auth.uid());
    if new.lifecycle_status='installed' and new.installed_at is null then new.installed_at=now(); end if;
    if new.lifecycle_status='active' and new.first_transaction_at is null then new.first_transaction_at=now(); end if;
  end if;
  return new;
end $$;
drop trigger if exists terminals_status_history on public.terminals;
create trigger terminals_status_history before insert or update of lifecycle_status on public.terminals
for each row execute function public.capture_terminal_status();

create or replace function public.audit_row_change()
returns trigger language plpgsql security definer set search_path=public
as $$
declare oldj jsonb; newj jsonb; rid text;
begin
  if tg_op='DELETE' then oldj=to_jsonb(old); rid=old.id::text;
  elsif tg_op='UPDATE' then oldj=to_jsonb(old); newj=to_jsonb(new); rid=new.id::text;
  else newj=to_jsonb(new); rid=new.id::text; end if;
  insert into public.audit_logs(actor_id,action,entity,entity_id,before_data,after_data)
  values(auth.uid(),tg_op,tg_table_name,rid,oldj,newj);
  if tg_op='DELETE' then return old; else return new; end if;
end $$;

do $$ declare t text; begin
  foreach t in array array['brokers','merchants','sales_points','terminals','leads','targets','commission_rules','commission_ledger','tasks','workflow_rules'] loop
    execute format('drop trigger if exists %I_audit on public.%I',t,t);
    execute format('create trigger %I_audit after insert or update or delete on public.%I for each row execute function public.audit_row_change()',t,t);
  end loop;
end $$;

alter table public.profiles enable row level security;
alter table public.regions enable row level security;
alter table public.brokers enable row level security;
alter table public.merchants enable row level security;
alter table public.sales_points enable row level security;
alter table public.terminals enable row level security;
alter table public.terminal_status_history enable row level security;
alter table public.leads enable row level security;
alter table public.targets enable row level security;
alter table public.commission_rules enable row level security;
alter table public.commission_ledger enable row level security;
alter table public.daily_transaction_metrics enable row level security;
alter table public.tasks enable row level security;
alter table public.workflow_rules enable row level security;
alter table public.audit_logs enable row level security;

-- Default-deny policies; authenticated access is granted according to application role.
create policy "profile self or manager read" on public.profiles for select to authenticated
using (id=auth.uid() or public.can_manage() or public.current_role()='bi_analyst');
create policy "profile managers write" on public.profiles for all to authenticated
using (public.current_role()='super_admin') with check (public.current_role()='super_admin');

do $$ declare t text; begin
  foreach t in array array['regions','brokers','merchants','sales_points','terminals','leads','targets','commission_rules','commission_ledger','daily_transaction_metrics','tasks','workflow_rules','terminal_status_history'] loop
    execute format('create policy %I_read on public.%I for select to authenticated using (true)',t,t);
    execute format('create policy %I_write on public.%I for all to authenticated using (public.can_manage()) with check (public.can_manage())',t,t);
  end loop;
end $$;

create policy "audit read managers" on public.audit_logs for select to authenticated
using (public.current_role() in ('super_admin','sales_manager','bi_analyst'));
create policy "audit insert authenticated" on public.audit_logs for insert to authenticated with check (actor_id=auth.uid() or actor_id is null);

grant usage on schema public to authenticated;
grant select,insert,update,delete on all tables in schema public to authenticated;
grant usage,select on all sequences in schema public to authenticated;

-- Row-level scope enforcement: broker users see only their own broker data;
-- regional managers see records belonging to their assigned region.
create or replace function public.can_access_broker(p_broker_id uuid)
returns boolean language sql stable security definer set search_path=public
as $$
  select coalesce(
    public.current_role() in ('super_admin','sales_manager','operations','bi_analyst')
    or exists (
      select 1 from public.profiles p
      left join public.brokers b on b.id=p_broker_id
      where p.id=auth.uid() and p.is_active and (
        (p.role='broker' and p.broker_id=p_broker_id)
        or (p.role='regional_manager' and p.region is not null and b.region_id in
          (select r.id from public.regions r where r.name=p.region))
      )
    ),false)
$$;

-- Replace broad read policies with scoped policies.
do $$ declare t text; begin
  foreach t in array array['regions','brokers','merchants','sales_points','terminals','leads','targets','commission_rules','commission_ledger','daily_transaction_metrics','tasks','workflow_rules','terminal_status_history'] loop
    execute format('drop policy if exists %I_read on public.%I',t,t);
    execute format('drop policy if exists %I_write on public.%I',t,t);
  end loop;
end $$;

create policy regions_scoped_read on public.regions for select to authenticated
using (public.current_role() in ('super_admin','sales_manager','operations','bi_analyst')
  or name=(select p.region from public.profiles p where p.id=auth.uid()));
create policy regions_admin_write on public.regions for all to authenticated
using (public.current_role() in ('super_admin','sales_manager'))
with check (public.current_role() in ('super_admin','sales_manager'));

create policy brokers_scoped_read on public.brokers for select to authenticated
using (public.can_access_broker(id));
create policy brokers_manager_write on public.brokers for all to authenticated
using (public.current_role() in ('super_admin','sales_manager','regional_manager','operations'))
with check (public.current_role() in ('super_admin','sales_manager','regional_manager','operations'));

create policy merchants_scoped_read on public.merchants for select to authenticated
using (public.current_role() in ('super_admin','sales_manager','operations','bi_analyst')
  or exists(select 1 from public.terminals t where t.merchant_id=merchants.id and public.can_access_broker(t.broker_id)));
create policy merchants_manager_write on public.merchants for all to authenticated
using (public.can_manage()) with check (public.can_manage());

create policy sales_points_scoped_read on public.sales_points for select to authenticated
using (public.can_access_broker(broker_id));
create policy sales_points_manager_write on public.sales_points for all to authenticated
using (public.can_manage()) with check (public.can_manage());

create policy terminals_scoped_read on public.terminals for select to authenticated
using (public.current_role() in ('super_admin','sales_manager','operations','bi_analyst') or public.can_access_broker(broker_id));
create policy terminals_manager_write on public.terminals for all to authenticated
using (public.can_manage()) with check (public.can_manage());

create policy terminal_history_scoped_read on public.terminal_status_history for select to authenticated
using (exists(select 1 from public.terminals t where t.id=terminal_id and
  (public.current_role() in ('super_admin','sales_manager','operations','bi_analyst') or public.can_access_broker(t.broker_id))));
create policy terminal_history_manager_write on public.terminal_status_history for all to authenticated
using (public.can_manage()) with check (public.can_manage());

create policy leads_scoped_read on public.leads for select to authenticated
using (public.current_role() in ('super_admin','sales_manager','operations','bi_analyst') or public.can_access_broker(broker_id));
create policy leads_manager_write on public.leads for all to authenticated
using (public.can_manage()) with check (public.can_manage());

create policy targets_scoped_read on public.targets for select to authenticated
using (public.current_role() in ('super_admin','sales_manager','operations','bi_analyst') or public.can_access_broker(broker_id));
create policy targets_manager_write on public.targets for all to authenticated
using (public.can_manage()) with check (public.can_manage());

create policy commission_rules_read on public.commission_rules for select to authenticated
using (public.current_role() in ('super_admin','sales_manager','operations','bi_analyst'));
create policy commission_rules_admin_write on public.commission_rules for all to authenticated
using (public.current_role() in ('super_admin','sales_manager'))
with check (public.current_role() in ('super_admin','sales_manager'));

create policy commission_ledger_scoped_read on public.commission_ledger for select to authenticated
using (public.current_role() in ('super_admin','sales_manager','operations','bi_analyst') or public.can_access_broker(broker_id));
create policy commission_ledger_manager_write on public.commission_ledger for all to authenticated
using (public.current_role() in ('super_admin','sales_manager'))
with check (public.current_role() in ('super_admin','sales_manager'));

create policy transaction_metrics_scoped_read on public.daily_transaction_metrics for select to authenticated
using (exists(select 1 from public.terminals t where t.id=terminal_id and
  (public.current_role() in ('super_admin','sales_manager','operations','bi_analyst') or public.can_access_broker(t.broker_id))));
create policy transaction_metrics_ops_write on public.daily_transaction_metrics for all to authenticated
using (public.current_role() in ('super_admin','sales_manager','operations'))
with check (public.current_role() in ('super_admin','sales_manager','operations'));

create policy tasks_scoped_read on public.tasks for select to authenticated
using (assigned_to=auth.uid() or created_by=auth.uid() or public.can_manage());
create policy tasks_manager_write on public.tasks for all to authenticated
using (public.can_manage() or assigned_to=auth.uid())
with check (public.can_manage() or assigned_to=auth.uid());

create policy workflow_rules_admin_read on public.workflow_rules for select to authenticated
using (public.current_role() in ('super_admin','sales_manager','operations'));
create policy workflow_rules_admin_write on public.workflow_rules for all to authenticated
using (public.current_role() in ('super_admin','sales_manager'))
with check (public.current_role() in ('super_admin','sales_manager'));


-- Auth bootstrap: create a profile automatically for each Auth user.
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
begin
  insert into public.profiles(id,full_name,phone,role,is_active)
  values(new.id,coalesce(nullif(new.raw_user_meta_data->>'full_name',''),split_part(coalesce(new.email,'کاربر'),'@',1)),new.phone,'viewer',true)
  on conflict(id) do nothing;
  return new;
end $$;
revoke all on function public.handle_new_auth_user() from public,anon,authenticated;
drop trigger if exists on_auth_user_created_sni on auth.users;
create trigger on_auth_user_created_sni after insert on auth.users
for each row execute function public.handle_new_auth_user();

-- One-time bootstrap for the first administrator; available only to signed-in users.
create or replace function public.bootstrap_first_admin()
returns boolean language plpgsql security definer set search_path=public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if exists(select 1 from public.profiles where role='super_admin') then raise exception 'An administrator is already configured'; end if;
  update public.profiles set role='super_admin',updated_at=now() where id=auth.uid() and is_active=true;
  if not found then raise exception 'Active profile not found'; end if;
  return true;
end $$;
revoke all on function public.bootstrap_first_admin() from public,anon;
grant execute on function public.bootstrap_first_admin() to authenticated;

-- Restrict internal trigger helpers and role-check functions from anonymous execution.
alter function public.touch_updated_at() set search_path=public,pg_temp;
revoke all on function public.audit_row_change() from public,anon,authenticated;
revoke all on function public.capture_terminal_status() from public,anon,authenticated;
revoke all on function public.current_role() from public,anon;
revoke all on function public.can_manage() from public,anon;
revoke all on function public.can_access_broker(uuid) from public,anon;
grant execute on function public.current_role() to authenticated;
grant execute on function public.can_manage() to authenticated;
grant execute on function public.can_access_broker(uuid) to authenticated;
drop policy if exists "audit insert authenticated" on public.audit_logs;
