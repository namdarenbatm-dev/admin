# SNI CRM — Operations and Reward Engine

The CRM is deployed separately from the existing root website. The root `index.html` remains untouched.

- CRM: https://namdarenbatm-dev.github.io/admin/crm/
- Reward model reference: https://namdarenbatm-dev.github.io/reward-techno/
- Database: Supabase project `aydgmrkzgjydcnxkcxyw` (Frankfurt)

## Main modules
- Broker, merchant, sales point, terminal, lead, target and task management
- Daily transaction CSV import and BI summaries
- Terminal lifecycle history and status-based workflow events
- User profiles and invitation flow through the `crm-admin` Edge Function
- Reward participants, referral hierarchy, first-purchase events, versioned rate configuration, calculation runs and immutable reward ledger
- Reward approval/payment state transitions through the `reward-status` Edge Function
- Duplicate approved/paid snapshots are blocked by a unique period constraint
- Reward budgets and rates use the exact Reward Techno default configuration; direct/indirect network rewards are charged to the agent basket as in the reference model

## Reward rules carried over from Techno Reward
- Two independent funding baskets: partner and agent.
- Partner registration and target rewards use the partner rates.
- Agent registration and target rewards use agent rates.
- The nearest upstream partner receives direct/indirect network registration rewards.
- Direct referral reward is paid only to the immediate referrer, once per first-purchase event.
- Referral reward eligibility requires completed registration, approved documents and a first purchase of at least one device.
- Each agent can have only one first-purchase record; edits update that record rather than create a second event.
- Referral cycles are rejected at database level.
- The six agent-side rates must reconcile to the agent budget per device before a run can be approved.

The default rate configuration is copied from the reference app's documented default model. All rates remain editable and versioned in `reward_model_config`.

## Transaction and commission boundaries
- Transaction data is imported from validated CSV files; a live PSP transaction API was intentionally excluded from this release.
- Commission rules and the commission ledger are available for configuration and record management. Automatic commission calculation/settlement is intentionally not activated until the business-approved basis, rate type, and payout formula are supplied; no financial formula is assumed.

## Period semantics
The reference model stores cumulative registered-device counts, not per-month registration deltas. For that reason, calculation dates label a snapshot/reporting period; they do not transform cumulative counts into period-only counts. First-purchase events are included up to the run end date. A period-specific payout model requires dated registration and target-device movements.

## Workflow automation
Database triggers emit `terminal.status_changed` and `lead.stage_changed`. Enabled workflow rules can use `create_task` or `log_only`; task conditions support `to_status`, `to_stage`, `task_title`, `description`, `priority` and `due_hours`.

## Edge Functions
- `crm-admin`: authenticated invitation and reward calculation endpoints.
- `reward-status`: authenticated approval/payment transitions.
Both functions verify the caller's Supabase session and role on the server. Secret API keys are read only from Supabase Edge Function environment variables and are not stored in GitHub or browser code.

## Deployment notes
- Database migration source: `crm/supabase/migrations/20261108_reward_engine_workflows.sql`
- Edge Function source is versioned under `crm/supabase/functions/`.
- The frontend uses only the publishable key; never put a secret/service-role key in the repository.
- The Supabase Auth leaked-password protection setting remains a dashboard-level action. Enable it under Authentication → Settings → Password Security.
- Unauthenticated browser smoke tests passed. Authenticated end-to-end testing, Supabase Auth URL/password-security configuration, and SMTP invitation-delivery confirmation are still required before production sign-off.
