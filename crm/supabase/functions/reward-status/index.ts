import { createClient } from "npm:@supabase/supabase-js@2";
const cors = {"Access-Control-Allow-Origin":"https://namdarenbatm-dev.github.io","Access-Control-Allow-Headers":"authorization, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,"Content-Type":"application/json"}});
function keys(name:string,legacy:string){const raw=Deno.env.get(name);if(raw){try{return JSON.parse(raw).default as string}catch{}}return Deno.env.get(legacy)||""}
const url=Deno.env.get("SUPABASE_URL")||"";
const pub=keys("SUPABASE_PUBLISHABLE_KEYS","SUPABASE_ANON_KEY");
const secret=keys("SUPABASE_SECRET_KEYS","SUPABASE_SERVICE_ROLE_KEY");
const admin=createClient(url,secret,{auth:{autoRefreshToken:false,persistSession:false}});
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return reply({error:"Method not allowed"},405);
 try{
  const auth=req.headers.get("Authorization")||"";
  const token=auth.replace(/^Bearer\s+/i,"");
  if(!token||token===auth)return reply({error:"Authentication required"},401);
  const user=createClient(url,pub,{global:{headers:{Authorization:auth}},auth:{autoRefreshToken:false,persistSession:false}});
  const {data:authData,error:authError}=await user.auth.getUser(token);
  if(authError||!authData.user)return reply({error:"Invalid session"},401);
  const {data:profile,error:profileError}=await admin.from("profiles").select("role,is_active").eq("id",authData.user.id).single();
  if(profileError||!profile?.is_active||!["super_admin","sales_manager"].includes(profile.role))return reply({error:"Insufficient permissions"},403);
  const body=await req.json();const id=String(body.run_id||"");const status=String(body.status||"");
  if(!id||!["approved","paid","void"].includes(status))return reply({error:"Invalid request"},400);
  const {data:run,error:readError}=await admin.from("reward_calculation_runs").select("id,status,totals").eq("id",id).single();
  if(readError||!run)return reply({error:"Run not found"},404);
  if(status==="approved"&&(run.status!=="calculated"||run.totals?.all_ok!==true))return reply({error:"Only a calculated run with all controls passing can be approved"},409);
  if(status==="paid"&&run.status!=="approved")return reply({error:"Only an approved run can be marked paid"},409);
  if(status==="void"&&run.status!=="calculated")return reply({error:"Only an unapproved calculated run can be voided"},409);
  const patch:Record<string,unknown>={status};
  if(status==="approved"){patch.approved_by=authData.user.id;patch.approved_at=new Date().toISOString()}
  if(status==="paid"){patch.paid_by=authData.user.id;patch.paid_at=new Date().toISOString()}
  if(status==="void")patch.void_reason=String(body.reason||"باطل‌شده توسط مدیر");
  const {data:changed,error:writeError}=await admin.from("reward_calculation_runs").update(patch).eq("id",id).eq("status",run.status).select("id,status,approved_at,paid_at").single();
  if(writeError)throw writeError;
  if(!changed)return reply({error:"Run status changed concurrently; refresh and retry"},409);
  return reply({ok:true,run:changed});
 }catch(e){return reply({error:e instanceof Error?e.message:"Unexpected error"},500)}
});
