-- Avoid per-row auth.uid() evaluation in selected RLS predicates.
drop policy if exists "profile self or manager read" on public.profiles;
create policy "profile self or manager read" on public.profiles for select to authenticated
using (id=(select auth.uid()) or public.can_manage() or public.current_role()='bi_analyst');
drop policy if exists regions_scoped_read on public.regions;
create policy regions_scoped_read on public.regions for select to authenticated
using (public.current_role() in ('super_admin','sales_manager','operations','bi_analyst')
  or name=(select p.region from public.profiles p where p.id=(select auth.uid())));
drop policy if exists tasks_scoped_read on public.tasks;
create policy tasks_scoped_read on public.tasks for select to authenticated
using (assigned_to=(select auth.uid()) or created_by=(select auth.uid()) or public.can_manage());