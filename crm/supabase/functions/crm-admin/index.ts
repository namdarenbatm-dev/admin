import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

function getKeyMap(name: string, fallbackName?: string) {
  const raw = Deno.env.get(name);
  if (raw) { try { return JSON.parse(raw) as Record<string,string>; } catch { /* legacy key below */ } }
  const fallback = fallbackName ? Deno.env.get(fallbackName) : null;
  if (fallback) return { default: fallback };
  return {};
}
const publishable = getKeyMap("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY").default;
const secret = getKeyMap("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY").default;
const url = Deno.env.get("SUPABASE_URL") ?? "";
const admin = createClient(url, secret, { auth: { autoRefreshToken: false, persistSession: false } });

const int = (v: unknown) => Math.max(0, Math.floor(Number(v) || 0));
const money = (v: unknown) => Math.round(Number(v) || 0);
const amount = (q: number, r: number) => q * r;

function nearestPartner(byId: Map<string, any>, agent: any) {
  const seen = new Set<string>();
  let cur = agent;
  while (cur?.id && !seen.has(cur.id)) {
    if (cur.participant_type === "partner") return cur;
    seen.add(cur.id);
    cur = cur.referrer_id ? byId.get(cur.referrer_id) : null;
  }
  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    if (!url || !publishable || !secret) return json({ error: "Supabase function keys are not configured" }, 500);
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token || token === authHeader) return json({ error: "Authentication required" }, 401);
    const userClient = createClient(url, publishable, { global: { headers: { Authorization: authHeader } }, auth: { autoRefreshToken: false, persistSession: false } });
    const { data: authData, error: authError } = await userClient.auth.getUser(token);
    if (authError || !authData.user) return json({ error: "Invalid session" }, 401);
    const { data: profile, error: profileError } = await admin.from("profiles").select("id,role,is_active").eq("id", authData.user.id).single();
    if (profileError || !profile?.is_active || !["super_admin", "sales_manager"].includes(profile.role)) {
      return json({ error: "Insufficient permissions" }, 403);
    }
    const body = await req.json();
    if (body.action === "invite_user") {
      const email = String(body.email || "").trim().toLowerCase();
      const fullName = String(body.full_name || "").trim();
      const role = String(body.role || "viewer");
      const allowed = ["sales_manager", "regional_manager", "broker", "bi_analyst", "operations", "viewer"];
      if (!/^\S+@\S+\.\S+$/.test(email) || !fullName || !allowed.includes(role)) return json({ error: "Email, full name or role is invalid" }, 400);
      const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, { data: { full_name: fullName } });
      if (inviteError) return json({ error: inviteError.message }, 400);
      const profilePatch: Record<string, unknown> = { full_name: fullName, role, is_active: true };
      if (body.phone) profilePatch.phone = String(body.phone).trim();
      if (body.region) profilePatch.region = String(body.region).trim();
      if (body.broker_id) profilePatch.broker_id = body.broker_id;
      const { error: updateError } = await admin.from("profiles").update(profilePatch).eq("id", invited.user.id);
      if (updateError) return json({ error: "User invited, but profile assignment failed: " + updateError.message, user_id: invited.user.id }, 500);
      return json({ ok: true, message: "Invitation sent", email, role });
    }
    if (body.action !== "calculate_rewards") return json({ error: "Unsupported action" }, 400);

    const start = String(body.period_start || "");
    const end = String(body.period_end || "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(start) || !/^\d{4}-\d{2}-\d{2}$/.test(end) || start > end) {
      return json({ error: "A valid date range is required" }, 400);
    }
    const [configRes, peopleRes, purchasesRes] = await Promise.all([
      admin.from("reward_model_config").select("config,version,assumptions").eq("id", 1).single(),
      admin.from("reward_participants").select("*").eq("is_active", true).limit(10000),
      admin.from("reward_first_purchases").select("*").lte("purchased_at", end).limit(10000),
    ]);
    if (configRes.error || peopleRes.error || purchasesRes.error) throw new Error(configRes.error?.message || peopleRes.error?.message || purchasesRes.error?.message);
    const config = configRes.data.config || {};
    const p = config.partner || {}, a = config.agent || {};
    const rates: Record<string, number> = {
      P_REG: money(p.regRate), P_TARGET: p.targetRateOverride == null ? money(p.budget) - money(p.regRate) : money(p.targetRateOverride),
      A_REG: money(a.regRate), A_TARGET: money(a.targetRate), REF_AGENT: money(a.refAgentRate),
      REF_PARTNER: money(a.refPartnerRate), OLD_REG_PARTNER: money(a.oldRegPartnerRate), NEW_REG_PARTNER: money(a.newRegPartnerRate),
    };
    const agentBudget = a.budgetOverride == null ? money(p.budget) : money(a.budgetOverride);
    const agentRateTotal = rates.A_REG + rates.A_TARGET + rates.REF_AGENT + rates.REF_PARTNER + rates.OLD_REG_PARTNER + rates.NEW_REG_PARTNER;
    const people = peopleRes.data || [];
    const byId = new Map(people.map((x: any) => [x.id, x]));
    const purchases = purchasesRes.data || [];
    const purchaseByAgent = new Map(purchases.map((x: any) => [x.participant_id, x]));
    const ledger: any[] = [];
    const add = (code: string, payee: string, qty: unknown, source: string | null = null) => {
      const q = int(qty); if (!q) return;
      const basket = ["P_REG","P_TARGET","REF_PARTNER","OLD_REG_PARTNER","NEW_REG_PARTNER"].includes(code) ? "partner" : "agent";
      const group = code.includes("REG") ? "reg" : code.includes("TARGET") ? "target" : "referral";
      ledger.push({ reward_code: code, payee_id: payee, source_id: source, basket, group_key: group, quantity: q, rate: rates[code], amount: amount(q, rates[code]) });
    };
    const issues: string[] = [];
    for (const person of people) {
      if (person.target_devices > person.reg_devices) issues.push("Target exceeds registered devices: " + person.name);
      if (person.participant_type === "partner") {
        add("P_REG", person.id, person.reg_devices);
        add("P_TARGET", person.id, person.target_devices);
      } else {
        add("A_REG", person.id, person.reg_devices);
        add("A_TARGET", person.id, person.target_devices);
        const partner = nearestPartner(byId, person);
        if (partner) add(person.referrer_id === partner.id ? "NEW_REG_PARTNER" : "OLD_REG_PARTNER", partner.id, person.reg_devices, person.id);
        const fp = purchaseByAgent.get(person.id);
        if (fp && fp.devices > person.reg_devices) issues.push("First purchase exceeds registered devices: " + person.name);
      }
    }
    const referralSeen = new Set<string>();
    for (const fp of purchases) {
      if (referralSeen.has(fp.participant_id)) { issues.push("Duplicate first purchase event: " + fp.participant_id); continue; }
      referralSeen.add(fp.participant_id);
      const agent = byId.get(fp.participant_id);
      if (!agent || agent.participant_type !== "agent" || !agent.referrer_id) continue;
      if (!agent.registration_completed || !agent.docs_approved || int(fp.devices) < 1) continue;
      const referrer = byId.get(agent.referrer_id);
      if (!referrer) { issues.push("Missing referrer for: " + agent.name); continue; }
      add(referrer.participant_type === "partner" ? "REF_PARTNER" : "REF_AGENT", referrer.id, fp.devices, agent.id);
    }
    if (issues.length) return json({ error: "Data validation failed", issues }, 422);

    const partnerDevices = people.filter((x: any) => x.participant_type === "partner").reduce((s: number,x: any)=>s+int(x.reg_devices),0);
    const agentDevices = people.filter((x: any) => x.participant_type === "agent").reduce((s: number,x: any)=>s+int(x.reg_devices),0);
    const partnerPool = money(p.budget) * partnerDevices;
    const agentPool = agentBudget * agentDevices;
    const partnerCommitted = ledger.filter(x=>x.basket==="partner").reduce((s,x)=>s+x.amount,0);
    const agentCommitted = ledger.filter(x=>x.basket==="agent").reduce((s,x)=>s+x.amount,0);
    const total = ledger.reduce((s,x)=>s+x.amount,0);
    const designOk = agentRateTotal === agentBudget;
    const partnerOk = partnerCommitted <= partnerPool;
    const agentOk = agentCommitted <= agentPool;
    const totals = {
      participants: people.length, partnerDevices, agentDevices, ledgerLines: ledger.length, total,
      partner: { pool: partnerPool, committed: partnerCommitted, remaining: partnerPool-partnerCommitted },
      agent: { pool: agentPool, committed: agentCommitted, remaining: agentPool-agentCommitted },
      controls: { rate_design: designOk, partner_budget: partnerOk, agent_budget: agentOk, data_reconciliation: true },
      all_ok: designOk && partnerOk && agentOk,
      assumptions: configRes.data.assumptions,
      note: "مدل منبع بر اساس تعداد تجمعی دستگاه‌های ثبت‌شده اجرا شده است؛ تاریخ دوره، بازه گزارش و نسخه محاسبه را مشخص می‌کند و به‌تنهایی تعدادها را دوره‌ای نمی‌کند."
    };
    const { data: run, error: runError } = await admin.from("reward_calculation_runs").insert({
      period_start: start, period_end: end, config_snapshot: { config, version: configRes.data.version },
      totals, created_by: authData.user.id, status: "calculated",
    }).select("id,period_start,period_end,status,created_at,totals").single();
    if (runError) throw runError;
    const rows = ledger.map(x=>({ ...x, run_id: run.id }));
    for (let i=0;i<rows.length;i+=500) {
      const { error } = await admin.from("reward_ledger").insert(rows.slice(i,i+500));
      if (error) {
        await admin.from("reward_calculation_runs").delete().eq("id",run.id);
        throw error;
      }
    }
    return json({ ok: true, run, totals });
  } catch (err) {
    return json({ error: err instanceof Error ? err.message : "Unexpected error" }, 500);
  }
});
