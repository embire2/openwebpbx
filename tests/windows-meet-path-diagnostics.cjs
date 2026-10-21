// QA-only independent path observations. Secret request values stay in memory.
const fs=require('node:fs');
const https=require('node:https');
const path=require('node:path');
const {execFile}=require('node:child_process');
const wsBooleans=['observed','connected','sent','response_received','closed_exact','large_sent','large_response_received'];
const wsPhases=['connect','send','receive','complete','unavailable'];
const wsErrors=['none','timeout','tls','websocket','other','unavailable'];
const pgCounts=['total','active','idle','idle_in_transaction','wait_lock','meeting_select','meeting_update','meeting_insert','meeting_other','meeting_wait_lock'];
const memberStates=['waiting','admitted','left','removed','unavailable','other'];
const httpErrors=['none','timeout','tls','http','invalid_json','other','unavailable'];
function exact(row,names){return !!row&&typeof row==='object'&&!Array.isArray(row)&&Object.keys(row).length===names.length&&names.every(name=>Object.hasOwn(row,name));}
function bounded(value,max){return Number.isInteger(value)&&value>=0&&value<=max;}
function wsDefault(){return {...Object.fromEntries(wsBooleans.map(name=>[name,false])),status_code:0,large_status_code:0,phase:'unavailable',error_kind:'unavailable',elapsed_ms:0};}
function pgDefault(){return {observed:false,read_only:false,query_visible:false,counts_capped:false,...Object.fromEntries(pgCounts.map(name=>[name,0])),error_kind:'unavailable'};}
function httpDefault(){return {observed:false,completed:false,ok:false,http_status:0,member_state:'unavailable',error_kind:'unavailable',elapsed_ms:0};}
function validateWs(row){return exact(row,[...wsBooleans,'status_code','large_status_code','phase','error_kind','elapsed_ms'])&&wsBooleans.every(name=>typeof row[name]==='boolean')&&bounded(row.status_code,699)&&bounded(row.large_status_code,699)&&bounded(row.elapsed_ms,6000)&&wsPhases.includes(row.phase)&&wsErrors.includes(row.error_kind)?{...row}:null;}
function validatePg(row){return exact(row,['observed','read_only','query_visible','counts_capped',...pgCounts,'error_kind'])&&['observed','read_only','query_visible','counts_capped'].every(name=>typeof row[name]==='boolean')&&pgCounts.every(name=>bounded(row[name],512))&&['none','timeout','database','unavailable'].includes(row.error_kind)?{...row}:null;}
function validateHttp(row){return exact(row,['observed','completed','ok','http_status','member_state','error_kind','elapsed_ms'])&&['observed','completed','ok'].every(name=>typeof row[name]==='boolean')&&bounded(row.http_status,599)&&bounded(row.elapsed_ms,5000)&&memberStates.includes(row.member_state)&&httpErrors.includes(row.error_kind)?{...row}:null;}
function defaults(){return {backend:wsDefault(),frontend:wsDefault(),database:pgDefault(),host_http:httpDefault(),guest_http:httpDefault()};}
function validate(row){if(!exact(row,['backend','frontend','database','host_http','guest_http']))return null;const out={backend:validateWs(row.backend),frontend:validateWs(row.frontend),database:validatePg(row.database),host_http:validateHttp(row.host_http),guest_http:validateHttp(row.guest_http)};return Object.values(out).every(Boolean)?out:null;}
function capture(page,origin){
 let token;
 page.on('request',request=>{try{const target=new URL(request.url());if(target.origin!==origin||target.pathname!=='/app/pbx_meet/api.php'||request.method()!=='POST')return;const value=request.headers()['authorization'];if(typeof value==='string'&&/^Bearer [a-f0-9]{64}$/.test(value))token=value.slice(7);}catch{}});
 return ()=>token;
}
function statusProbe(origin,ca,token){
 if(typeof token!=='string'||!/^[a-f0-9]{64}$/.test(token))return Promise.resolve(httpDefault());
 const row={...httpDefault(),observed:true},started=performance.now();
 return new Promise(resolve=>{
  let timer,request,finished=false;
  const finish=kind=>{if(finished)return;finished=true;clearTimeout(timer);row.error_kind=kind;row.elapsed_ms=Math.min(5000,Math.max(0,Math.round(performance.now()-started)));resolve(validateHttp(row)||httpDefault());};
  try{
   const url=new URL('/app/pbx_meet/api.php',origin);
   if(url.protocol!=='https:')return finish('other');
   const body=Buffer.from(JSON.stringify({action:'status'}));
   request=https.request(url,{method:'POST',ca,rejectUnauthorized:true,agent:false,headers:{'Content-Type':'application/json','Content-Length':body.length,Origin:origin,Authorization:'Bearer '+token}},response=>{
    row.http_status=response.statusCode||0;let size=0,chunks=[];
    response.on('data',chunk=>{size+=chunk.length;if(size>8192){request.destroy();finish('invalid_json');}else chunks.push(chunk);});
    response.on('end',()=>{if(finished)return;row.completed=true;try{const data=JSON.parse(Buffer.concat(chunks).toString('utf8'));row.member_state=memberStates.includes(data?.state)?data.state:'other';row.ok=row.http_status===200&&memberStates.includes(data?.state);finish(row.http_status!==200?'http':row.ok?'none':'invalid_json');}catch{finish(row.http_status!==200?'http':'invalid_json');}});
    response.on('error',()=>finish('other'));
   });
   request.on('error',error=>finish(error.code==='OPENWEB_QA_TIMEOUT'?'timeout':/CERT|TLS|SSL|SELF_SIGNED|UNABLE_TO_VERIFY/.test(String(error.code||''))?'tls':'other'));
   timer=setTimeout(()=>{const error=Error('deadline');error.code='OPENWEB_QA_TIMEOUT';request.destroy(error);finish('timeout');},4000);
   request.end(body);
  }catch{request?.destroy();finish('other');}
 });
}
function child(executable,args,timeout){return new Promise(resolve=>{execFile(executable,args,{timeout,maxBuffer:16384,windowsHide:true},(error,stdout)=>{if(error){resolve(null);return;}try{resolve(JSON.parse(stdout.replace(/^\uFEFF/,'')));}catch{resolve(null);}});});}
async function observe(settings,label,secrets={}){
 const row=defaults(),probe=settings.pathProbe;
 if(!probe||!['before','after'].includes(label))return row;
 const report=path.join(path.dirname(settings.report),'meeting-wss-'+label+'.safe.json');
 let ca;try{ca=fs.readFileSync(probe.caFile);if(ca.length>65536)return row;}catch{return row;}
 const wss=async()=>{
  if(fs.existsSync(report))return;
  await child(probe.powershell,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',probe.wssScript,'-Hostname',new URL(settings.origin).hostname,'-Port',new URL(settings.origin).port||'443','-ReportPath',report,'-DisposableHostedRunner'],17000);
  try{if(!fs.lstatSync(report).isFile()||fs.statSync(report).size>16384)return;const reportRow=JSON.parse(fs.readFileSync(report,'utf8').replace(/^\uFEFF/,''));if(exact(reportRow,['schema','state','backend','frontend'])&&reportRow.schema===1&&reportRow.state==='observed'){row.backend=validateWs(reportRow.backend)||wsDefault();row.frontend=validateWs(reportRow.frontend)||wsDefault();}}catch{}
 };
 await Promise.allSettled([wss(),child(probe.php,[probe.fixtureScript,'meeting-path-state',probe.fixtureInput],6000).then(value=>{row.database=validatePg(value)||pgDefault();}),statusProbe(settings.origin,ca,secrets.host).then(value=>{row.host_http=value;}),statusProbe(settings.origin,ca,secrets.guest).then(value=>{row.guest_http=value;})]);
 return validate(row)||defaults();
}
module.exports={defaults,validate,validateWs,validatePg,validateHttp,capture,statusProbe,observe};
