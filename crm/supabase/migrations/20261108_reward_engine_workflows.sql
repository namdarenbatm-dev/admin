-- SNI CRM extension migration (applied 2026-11-08)
-- Adds the Reward Techno reward model, safe workflow automation and private authorization helpers.
-- Existing root website and existing CRM tables are not dropped or replaced.

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

alter function public.current_role() set schema private;
alter function public.can_manage() set schema private;
alter function public.can_access_broker(uuid) set schema private;
alter function public.can_manage_broker(uuid) set schema private;
alter function public.bootstrap_first_admin() set schema private;

create or replace function private.current_role()
returns public.app_role language sql stable security definer
set search_path=public,private,pg_temp
as $$ select role from public.profiles where id=auth.uid() and is_active=true $$;
create or replace function private.can_manage()
returns boolean language sql stable security definer
set search_path=public,private,pg_temp
as $$ select coalesce(private.current_role() in ('super_admin','sales_manager','operations'),false) $$;
create or replace function private.can_access_broker(p_broker_id uuid)
returns boolean language sql stable security definer
set search_path=public,private,pg_temp
as $$
 select coalesce(private.current_role() in ('super_admin','sales_manager','operations','bi_analyst')
 or exists(select 1 from public.profiles p left join public.brokers b on b.id=p_broker_id
 where p.id=auth.uid() and p.is_active and
 ((p.role='broker' and p.broker_id=p_broker_id) or
 (p.role='regional_manager' and p.region is not null and b.region_id in
 (select r.id from public.regions r where r.name=p.region)))),false)
$$;
create or replace function private.can_manage_broker(p_broker_id uuid)
returns boolean language sql stable security definer
set search_path=public,private,pg_temp
as $$
 select coalesce(private.current_role() in ('super_admin','sales_manager','operations')
 or exists(select 1 from public.profiles p join public.brokers b on b.id=p_broker_id
 join public.regions r on r.id=b.region_id where p.id=auth.uid() and p.is_active
 and p.role='regional_manager' and p.region=r.name),false)
$$;
alter function private.current_role() set search_path=public,private,pg_temp;
alter function private.can_manage() set search_path=public,private,pg_temp;
alter function private.can_access_broker(uuid) set search_path=public,private,pg_temp;
alter function private.can_manage_broker(uuid) set search_path=public,private,pg_temp;
revoke all on function private.current_role() from public,anon;
revoke all on function private.can_manage() from public,anon;
revoke all on function private.can_access_broker(uuid) from public,anon;
revoke all on function private.can_manage_broker(uuid) from public,anon;
grant execute on function private.current_role() to authenticated;
grant execute on function private.can_manage() to authenticated;
grant execute on function private.can_access_broker(uuid) to authenticated;
grant execute on function private.can_manage_broker(uuid) to authenticated;
revoke all on function private.bootstrap_first_admin() from public,anon,authenticated;

create sequence if not exists public.reward_first_purchase_seq;
create table if not exists public.reward_model_config (
 id integer primary key default 1 check(id=1), model_name text not null default 'Techno Reward',
 currency text not null default 'IRR', config jsonb not null, assumptions jsonb not null default '{}'::jsonb,
 version integer not null default 1, is_active boolean not null default true,
 updated_by uuid references public.profiles(id), updated_at timestamptz not null default now()
);
insert into public.reward_model_config(id,model_name,currency,config,assumptions) values
(1,'Techno Reward','IRR',
'{"partner":{"approvedPrice":20000000,"budget":1000000,"regRate":500000,"targetRateOverride":null},"agent":{"approvedPriceOverride":null,"budgetOverride":null,"regRate":400000,"targetRate":200000,"refAgentRate":50000,"refPartnerRate":50000,"oldRegPartnerRate":150000,"newRegPartnerRate":150000}}'::jsonb,
'{"budget_basis":"per_registered_device","separate_baskets":true,"referral_direct_only":true,"referral_requires_registration_docs_first_purchase":true,"one_first_purchase_per_agent":true,"network_partner":"nearest_ancestor_partner","agent_direct_vs_indirect":"direct_if_referrer_is_partner"}'::jsonb)
on conflict(id) do nothing;

create table if not exists public.reward_participants (
 id uuid primary key default gen_random_uuid(), name text not null,
 participant_type text not null check(participant_type in ('partner','agent')),
 broker_id uuid references public.brokers(id), referrer_id uuid references public.reward_participants(id),
 registration_completed boolean not null default false, docs_approved boolean not null default false,
 reg_devices integer not null default 0 check(reg_devices>=0),
 target_devices integer not null default 0 check(target_devices>=0 and target_devices<=reg_devices),
 is_active boolean not null default true, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(referrer_id is null or referrer_id<>id), check(participant_type='agent' or referrer_id is null)
);
create index if not exists idx_reward_participants_referrer on public.reward_participants(referrer_id);
create index if not exists idx_reward_participants_broker on public.reward_participants(broker_id);

create table if not exists public.reward_first_purchases (
 id uuid primary key default gen_random_uuid(),
 event_code text not null unique default ('FP-'||lpad(nextval('public.reward_first_purchase_seq')::text,4,'0')),
 participant_id uuid not null unique references public.reward_participants(id) on delete restrict,
 devices integer not null check(devices>0), purchased_at date not null default current_date,
 created_by uuid references public.profiles(id), created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.reward_calculation_runs (
 id uuid primary key default gen_random_uuid(), period_start date not null, period_end date not null,
 config_snapshot jsonb not null, totals jsonb not null default '{}'::jsonb,
 status text not null default 'calculated' check(status in ('calculated','approved','paid','void')),
 created_by uuid references public.profiles(id), created_at timestamptz not null default now(),
 approved_by uuid references public.profiles(id), approved_at timestamptz,
 paid_by uuid references public.profiles(id), paid_at timestamptz, void_reason text,
 check(period_end>=period_start)
);
create table if not exists public.reward_ledger (
 id uuid primary key default gen_random_uuid(), run_id uuid not null references public.reward_calculation_runs(id) on delete cascade,
 reward_code text not null, payee_id uuid not null references public.reward_participants(id),
 source_id uuid references public.reward_participants(id), basket text not null check(basket in ('partner','agent')),
 group_key text not null check(group_key in ('reg','target','referral')),
 quantity integer not null check(quantity>0), rate numeric(18,2) not null check(rate>=0),
 amount numeric(20,2) not null check(amount>=0), created_at timestamptz not null default now()
);
create index if not exists idx_reward_ledger_run on public.reward_ledger(run_id);
create index if not exists idx_reward_ledger_payee on public.reward_ledger(payee_id);

alter table public.reward_model_config enable row level security;
alter table public.reward_participants enable row level security;
alter table public.reward_first_purchases enable row level security;
alter table public.reward_calculation_runs enable row level security;
alter table public.reward_ledger enable row level security;

create policy reward_config_read on public.reward_model_config for select to authenticated
using(private.current_role() in ('super_admin','sales_manager','operations','bi_analyst'));
create policy reward_config_insert on public.reward_model_config for insert to authenticated
with check(private.current_role() in ('super_admin','sales_manager'));
create policy reward_config_update on public.reward_model_config for update to authenticated
using(private.current_role() in ('super_admin','sales_manager')) with check(private.current_role() in ('super_admin','sales_manager'));
create policy reward_config_delete on public.reward_model_config for delete to authenticated
using(private.current_role() in ('super_admin','sales_manager'));

create policy reward_participants_read on public.reward_participants for select to authenticated
using(private.current_role() in ('super_admin','sales_manager','operations','bi_analyst') or (broker_id is not null and private.can_access_broker(broker_id)));
create policy reward_participants_insert on public.reward_participants for insert to authenticated
with check((broker_id is not null and private.can_manage_broker(broker_id)) or (broker_id is null and private.can_manage()));
create policy reward_participants_update on public.reward_participants for update to authenticated
using((broker_id is not null and private.can_manage_broker(broker_id)) or (broker_id is null and private.can_manage()))
with check((broker_id is not null and private.can_manage_broker(broker_id)) or (broker_id is null and private.can_manage()));
create policy reward_participants_delete on public.reward_participants for delete to authenticated
using((broker_id is not null and private.can_manage_broker(broker_id)) or (broker_id is null and private.can_manage()));

create policy reward_first_purchases_read on public.reward_first_purchases for select to authenticated
using(exists(select 1 from public.reward_participants p where p.id=participant_id and
(private.current_role() in ('super_admin','sales_manager','operations','bi_analyst') or (p.broker_id is not null and private.can_access_broker(p.broker_id)))));
create policy reward_first_purchases_insert on public.reward_first_purchases for insert to authenticated
with check(exists(select 1 from public.reward_participants p where p.id=participant_id and
((p.broker_id is not null and private.can_manage_broker(p.broker_id)) or (p.broker_id is null and private.can_manage()))));
create policy reward_first_purchases_update on public.reward_first_purchases for update to authenticated
using(exists(select 1 from public.reward_participants p where p.id=participant_id and
((p.broker_id is not null and private.can_manage_broker(p.broker_id)) or (p.broker_id is null and private.can_manage()))))
with check(exists(select 1 from public.reward_participants p where p.id=participant_id and
((p.broker_id is not null and private.can_manage_broker(p.broker_id)) or (p.broker_id is null and private.can_manage()))));
create policy reward_first_purchases_delete on public.reward_first_purchases for delete to authenticated
using(exists(select 1 from public.reward_participants p where p.id=participant_id and
((p.broker_id is not null and private.can_manage_broker(p.broker_id)) or (p.broker_id is null and private.can_manage()))));

create policy reward_runs_read on public.reward_calculation_runs for select to authenticated
using(private.current_role() in ('super_admin','sales_manager','operations','bi_analyst'));
create policy reward_ledger_read on public.reward_ledger for select to authenticated
using(private.current_role() in ('super_admin','sales_manager','operations','bi_analyst'));
revoke insert,update,delete on public.reward_calculation_runs,public.reward_ledger from authenticated;
grant select on public.reward_calculation_runs,public.reward_ledger to authenticated;
grant select,insert,update,delete on public.reward_model_config,public.reward_participants,public.reward_first_purchases to authenticated;
grant usage,select on sequence public.reward_first_purchase_seq to authenticated;

create or replace function private.prevent_reward_referral_cycle()
returns trigger language plpgsql security definer set search_path=public,private,pg_temp
as $$
declare v_cycle boolean;
begin
 if new.referrer_id is null then return new; end if;
 if new.participant_type<>'agent' then raise exception 'Only agents can have a referrer'; end if;
 with recursive ancestors(id,referrer_id,path) as (
  select p.id,p.referrer_id,array[p.id] from public.reward_participants p where p.id=new.referrer_id
  union all select p.id,p.referrer_id,a.path||p.id from public.reward_participants p
  join ancestors a on p.id=a.referrer_id where not p.id=any(a.path)
 ) select exists(select 1 from ancestors where id=new.id) into v_cycle;
 if v_cycle then raise exception 'Referral cycle is not allowed'; end if;
 return new;
end $$;
revoke all on function private.prevent_reward_referral_cycle() from public,anon,authenticated;
drop trigger if exists reward_referral_cycle_guard on public.reward_participants;
create trigger reward_referral_cycle_guard before insert or update of referrer_id,participant_type
on public.reward_participants for each row execute function private.prevent_reward_referral_cycle();

create table if not exists public.workflow_events (
 id uuid primary key default gen_random_uuid(), event_key text not null, entity_type text not null,
 entity_id uuid not null, broker_id uuid references public.brokers(id),
 payload jsonb not null default '{}'::jsonb, processed_at timestamptz, created_at timestamptz not null default now()
);
create index if not exists idx_workflow_events_pending on public.workflow_events(processed_at,created_at);
alter table public.workflow_events enable row level security;
create policy workflow_events_read on public.workflow_events for select to authenticated
using(private.current_role() in ('super_admin','sales_manager','operations','bi_analyst'));
grant select on public.workflow_events to authenticated;

create or replace function private.apply_workflow_event()
returns trigger language plpgsql security definer set search_path=public,private,pg_temp
as $$
declare v_event text; v_payload jsonb; r record; v_title text; v_priority text; v_hours integer;
begin
 if tg_table_name='terminals' then
  if tg_op='UPDATE' and old.lifecycle_status is distinct from new.lifecycle_status then
   v_event:='terminal.status_changed';
   v_payload:=jsonb_build_object('from_status',old.lifecycle_status,'to_status',new.lifecycle_status,'terminal_code',new.terminal_code);
  else return new; end if;
 elsif tg_table_name='leads' then
  if tg_op='UPDATE' and old.stage is distinct from new.stage then
   v_event:='lead.stage_changed'; v_payload:=jsonb_build_object('from_stage',old.stage,'to_stage',new.stage,'title',new.title);
  else return new; end if;
 else return new; end if;
 insert into public.workflow_events(event_key,entity_type,entity_id,broker_id,payload)
 values(v_event,tg_table_name,new.id,new.broker_id,v_payload);
 for r in select * from public.workflow_rules where is_enabled and event_key=v_event loop
  if (r.conditions->>'to_status' is null or r.conditions->>'to_status'=v_payload->>'to_status')
   and (r.conditions->>'to_stage' is null or r.conditions->>'to_stage'=v_payload->>'to_stage')
   and r.action_key in ('create_task','log_only') then
   if r.action_key='create_task' then
    v_title:=coalesce(nullif(r.conditions->>'task_title',''),r.name);
    v_priority:=case when r.conditions->>'priority' in ('low','normal','high','urgent') then r.conditions->>'priority' else 'normal' end;
    v_hours:=greatest(1,least(coalesce((r.conditions->>'due_hours')::integer,24),720));
    insert into public.tasks(title,description,broker_id,terminal_id,created_by,priority,due_at)
    values(v_title,coalesce(r.conditions->>'description',v_payload::text),new.broker_id,
    case when tg_table_name='terminals' then new.id else null end,auth.uid(),v_priority,now()+make_interval(hours=>v_hours));
   end if;
  end if;
 end loop;
 update public.workflow_events set processed_at=now()
 where event_key=v_event and entity_type=tg_table_name and entity_id=new.id and processed_at is null;
 return new;
end $$;
revoke all on function private.apply_workflow_event() from public,anon,authenticated;
drop trigger if exists sni_terminal_workflow on public.terminals;
create trigger sni_terminal_workflow after update of lifecycle_status on public.terminals
for each row execute function private.apply_workflow_event();
drop trigger if exists sni_lead_workflow on public.leads;
create trigger sni_lead_workflow after update of stage on public.leads
for each row execute function private.apply_workflow_event();

create index if not exists idx_reward_runs_approved_by on public.reward_calculation_runs(approved_by);
create index if not exists idx_reward_runs_created_by on public.reward_calculation_runs(created_by);
create index if not exists idx_reward_runs_paid_by on public.reward_calculation_runs(paid_by);
create index if not exists idx_reward_purchases_created_by on public.reward_first_purchases(created_by);
create index if not exists idx_reward_ledger_source on public.reward_ledger(source_id);
create index if not exists idx_reward_config_updated_by on public.reward_model_config(updated_by);
create index if not exists idx_workflow_events_broker on public.workflow_events(broker_id);
notify pgrst,'reload schema';


-- Follow-up fix: history must be inserted AFTER the terminal row exists.
-- Timestamp fields are still assigned in the BEFORE trigger.
create or replace function public.capture_terminal_status()
returns trigger language plpgsql security definer
set search_path=public,private,pg_temp
as $$
begin
 if new.lifecycle_status='installed' and new.installed_at is null then new.installed_at=now(); end if;
 if new.lifecycle_status='active' and new.first_transaction_at is null then new.first_transaction_at=now(); end if;
 return new;
end $$;
revoke all on function public.capture_terminal_status() from public,anon,authenticated;

create or replace function private.write_terminal_status_history()
returns trigger language plpgsql security definer
set search_path=public,private,pg_temp
as $$
begin
 if tg_op='INSERT' then
  insert into public.terminal_status_history(terminal_id,from_status,to_status,changed_by,note)
  values(new.id,null,new.lifecycle_status,auth.uid(),'ایجاد پایانه');
 elsif old.lifecycle_status is distinct from new.lifecycle_status then
  insert into public.terminal_status_history(terminal_id,from_status,to_status,changed_by)
  values(new.id,old.lifecycle_status,new.lifecycle_status,auth.uid());
 end if;
 return new;
end $$;
revoke all on function private.write_terminal_status_history() from public,anon,authenticated;
drop trigger if exists terminals_status_history on public.terminals;
drop trigger if exists terminals_status_timestamps on public.terminals;
create trigger terminals_status_timestamps before insert or update of lifecycle_status on public.terminals
for each row execute function public.capture_terminal_status();
create trigger terminals_status_history after insert or update of lifecycle_status on public.terminals
for each row execute function private.write_terminal_status_history();

-- Audit all reward model and calculation records.
do $$
declare t text;
begin
 foreach t in array array['reward_model_config','reward_participants','reward_first_purchases','reward_calculation_runs','reward_ledger'] loop
  execute format('drop trigger if exists %I_audit on public.%I',t,t);
  execute format('create trigger %I_audit after insert or update or delete on public.%I for each row execute function public.audit_row_change()',t,t);
 end loop;
end $$;
