-- Tighten SNI CRM broker and regional write scopes.
create or replace function public.can_manage()
returns boolean language sql stable security definer set search_path=public,pg_temp
as $$ select coalesce(public.current_role() in ('super_admin','sales_manager','operations'),false) $$;

create or replace function public.can_manage_broker(p_broker_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp
as $$
 select coalesce(
   public.current_role() in ('super_admin','sales_manager','operations')
   or exists (
     select 1 from public.profiles p
     join public.brokers b on b.id=p_broker_id
     join public.regions r on r.id=b.region_id
     where p.id=auth.uid() and p.is_active and p.role='regional_manager'
       and p.region=r.name
   ), false)
$$;
revoke all on function public.can_manage_broker(uuid) from public,anon;
grant execute on function public.can_manage_broker(uuid) to authenticated;

drop policy if exists brokers_manager_write on public.brokers;
create policy brokers_manager_write on public.brokers for all to authenticated using (public.can_manage_broker(id)) with check (public.can_manage_broker(id));
drop policy if exists sales_points_manager_write on public.sales_points;
create policy sales_points_manager_write on public.sales_points for all to authenticated using (public.can_manage_broker(broker_id)) with check (public.can_manage_broker(broker_id));
drop policy if exists terminals_manager_write on public.terminals;
create policy terminals_manager_write on public.terminals for all to authenticated using (public.can_manage_broker(broker_id)) with check (public.can_manage_broker(broker_id));
drop policy if exists leads_manager_write on public.leads;
create policy leads_manager_write on public.leads for all to authenticated using (public.can_manage_broker(broker_id)) with check (public.can_manage_broker(broker_id));
drop policy if exists targets_manager_write on public.targets;
create policy targets_manager_write on public.targets for all to authenticated using (public.can_manage_broker(broker_id)) with check (public.can_manage_broker(broker_id));
drop policy if exists commission_ledger_manager_write on public.commission_ledger;
create policy commission_ledger_manager_write on public.commission_ledger for all to authenticated using (public.can_manage_broker(broker_id)) with check (public.can_manage_broker(broker_id));
drop policy if exists merchants_manager_write on public.merchants;
create policy merchants_manager_write on public.merchants for all to authenticated
using (public.can_manage() or exists(select 1 from public.terminals t where t.merchant_id=merchants.id and public.can_manage_broker(t.broker_id)))
with check (public.can_manage() or exists(select 1 from public.terminals t where t.merchant_id=merchants.id and public.can_manage_broker(t.broker_id)));
drop policy if exists tasks_manager_write on public.tasks;
create policy tasks_manager_write on public.tasks for all to authenticated using (public.can_manage_broker(broker_id) or assigned_to=(select auth.uid())) with check (public.can_manage_broker(broker_id) or assigned_to=(select auth.uid()));
drop policy if exists terminal_history_manager_write on public.terminal_status_history;
