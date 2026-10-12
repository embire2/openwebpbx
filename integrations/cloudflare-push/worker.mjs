/* SPDX-License-Identifier: AGPL-3.0-or-later */
let access;
const refreshes=new Map();
const json=(value,status=200,headers={})=>Response.json(value,{status,headers:{'Cache-Control':'no-store',...headers}});
const b64=bytes=>btoa(String.fromCharCode(...new Uint8Array(bytes))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
const encoder=new TextEncoder();
async function equalSecret(a,b){
  if(!a||!b)return false;
  const [x,y]=await Promise.all([crypto.subtle.digest('SHA-256',encoder.encode(a)),crypto.subtle.digest('SHA-256',encoder.encode(b))]);
  const xa=new Uint8Array(x),ya=new Uint8Array(y);let different=0;for(let i=0;i<xa.length;i++)different|=xa[i]^ya[i];return different===0;
}
async function boundedJson(response){
  const reader=response.body?.getReader();if(!reader)return null;let size=0;const parts=[];
  while(true){const {value,done}=await reader.read();if(done)break;size+=value.byteLength;if(size>65536){await reader.cancel();throw Error('Response too large')}parts.push(value)}
  const bytes=new Uint8Array(size);let offset=0;for(const part of parts){bytes.set(part,offset);offset+=part.byteLength}
  try{return JSON.parse(new TextDecoder().decode(bytes))}catch{return null}
}
async function googleToken(account,send){
  const identity=b64(await crypto.subtle.digest('SHA-256',encoder.encode(account.client_email+'\n'+account.project_id+'\n'+account.private_key)));
  if(access?.identity===identity && access.until>Date.now()+120000)return access.token;
  if(refreshes.has(identity))return refreshes.get(identity);
  const refresh=(async()=>{
    const now=Math.floor(Date.now()/1000);
    const signing=b64(encoder.encode(JSON.stringify({alg:'RS256',typ:'JWT'})))+'.'+b64(encoder.encode(JSON.stringify({iss:account.client_email,scope:'https://www.googleapis.com/auth/firebase.messaging',aud:'https://oauth2.googleapis.com/token',iat:now,exp:now+3600})));
    const pem=account.private_key.replace(/-----[^-]+-----|\s/g,'');
    const key=await crypto.subtle.importKey('pkcs8',Uint8Array.from(atob(pem),c=>c.charCodeAt(0)),{name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['sign']);
    if(key.algorithm.modulusLength<2048)throw Error('Invalid configuration');
    const assertion=signing+'.'+b64(await crypto.subtle.sign('RSASSA-PKCS1-v1_5',key,encoder.encode(signing)));
    const response=await send('https://oauth2.googleapis.com/token',{method:'POST',redirect:'error',body:new URLSearchParams({grant_type:'urn:ietf:params:oauth:grant-type:jwt-bearer',assertion}),signal:AbortSignal.timeout(8000)});
    const result=await boundedJson(response);
    if(!response.ok||typeof result?.access_token!=='string'||result.access_token.length<10||result.access_token.length>8192||/[\s\x00-\x1f\x7f]/.test(result.access_token)||!Number.isInteger(result.expires_in)||result.expires_in<=0)throw Error('Authentication unavailable');
    access={identity,token:result.access_token,until:Date.now()+Math.min(result.expires_in,3600)*1000};return access.token;
  })();
  refreshes.set(identity,refresh);try{return await refresh}finally{refreshes.delete(identity)}
}
async function webPush(input,send){
  const allowed=['authorization','body','endpoint','transport','ttl','urgency'];
  if(Object.keys(input).some(k=>!allowed.includes(k))||typeof input.endpoint!=='string'||!/^https:\/\/fcm\.googleapis\.com\/fcm\/send\/[A-Za-z0-9_:\-.]{20,4000}$/.test(input.endpoint)||typeof input.body!=='string'||input.body.length>2048||!/^[A-Za-z0-9_-]+$/.test(input.body)||!Number.isInteger(input.ttl)||input.ttl<1||input.ttl>60||!['high','normal'].includes(input.urgency))return json({error:'Invalid call'},400);
  const auth=typeof input.authorization==='string'&&input.authorization.match(/^vapid t=([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+), k=([A-Za-z0-9_-]{87})$/);if(!auth)return json({error:'Invalid call'},400);
  const decode=s=>Uint8Array.from(atob(s.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
  const parts=auth[1].split('.'),header=JSON.parse(new TextDecoder().decode(decode(parts[0]))),claims=JSON.parse(new TextDecoder().decode(decode(parts[1]))),now=Math.floor(Date.now()/1000);
  if(header.alg!=='ES256'||claims.aud!=='https://fcm.googleapis.com'||!Number.isInteger(claims.exp)||claims.exp<=now||claims.exp>now+86400)return json({error:'Invalid call'},400);
  const key=await crypto.subtle.importKey('raw',decode(auth[2]),{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
  if(!await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,decode(parts[2]),encoder.encode(parts[0]+'.'+parts[1])))return json({error:'Invalid call'},400);
  const body=decode(input.body);if(body.length<103||body[20]!==65||body[21]!==4||new DataView(body.buffer,body.byteOffset,body.byteLength).getUint32(16)!==4096)return json({error:'Invalid call'},400);
  const reply=await send(input.endpoint,{method:'POST',redirect:'error',headers:{Authorization:input.authorization,'Content-Type':'application/octet-stream','Content-Encoding':'aes128gcm',TTL:String(input.ttl),Urgency:input.urgency},body,signal:AbortSignal.timeout(8000)});
  if(reply.ok)return json({ok:true});if([404,410].includes(reply.status))return json({error:'Phone registration expired',code:'UNREGISTERED'},410);
  const retry=Number(reply.headers.get('Retry-After'));return json({error:'Delivery unavailable',code:'DELIVERY_UNAVAILABLE'},503,{'Retry-After':String(Math.max(reply.status===429?60:1,Math.min(Number.isFinite(retry)&&retry>0?retry:3,300)))});
}
export async function relay(request,env,send=fetch){
  if(request.method!=='POST')return json({error:'Method unavailable'},405);
  if(request.headers.has('Origin')||!env.PBX_RELAY_TOKEN||!/^[A-Za-z0-9_-]{32,256}$/.test(env.PBX_RELAY_TOKEN)||!await equalSecret(request.headers.get('Authorization'),`Bearer ${env.PBX_RELAY_TOKEN}`))return json({error:'Access denied'},403);
  if((request.headers.get('Content-Type')??'').split(';')[0].trim().toLowerCase()!=='application/json')return json({error:'Send JSON'},415);
  const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
  try{
    const reader=request.body?.getReader();if(!reader)return json({error:'Missing request'},400);let size=0;const parts=[];
    while(true){const {value,done}=await reader.read();if(done)break;size+=value.byteLength;if(size>8192){await reader.cancel();return json({error:'Request too large'},413)}parts.push(value)}
    const bytes=new Uint8Array(size);let offset=0;for(const part of parts){bytes.set(part,offset);offset+=part.byteLength}
    let input;try{input=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes))}catch{return json({error:'Invalid call'},400)}
    if(input?.transport==='webpush')return await webPush(input,send);
    const d=input?.data,expiry=Number(d?.expires),now=Math.floor(Date.now()/1000);
    if(!input||Array.isArray(input)||typeof input.project_id!=='string'||!/^[a-z][a-z0-9-]{4,62}$/.test(input.project_id)||Object.keys(input).some(k=>!['project_id','token','data'].includes(k))||!d||Array.isArray(d)||Object.keys(d).sort().join(',')!=='device_id,event,expires,request_id'||typeof input.token!=='string'||input.token.length<20||input.token.length>4096||!/^[a-zA-Z0-9_:\-.]+$/.test(input.token)||typeof d.request_id!=='string'||!uuid.test(d.request_id)||typeof d.device_id!=='string'||!uuid.test(d.device_id)||!['incoming','ended'].includes(d.event)||typeof d.expires!=='string'||!/^\d+$/.test(d.expires)||!Number.isInteger(expiry)||expiry>now+120)return json({error:'Invalid call'},400);
    if(expiry<=now)return json({error:'Call expired',code:'CALL_EXPIRED'},410);
    const account=JSON.parse(env.FCM_SERVICE_ACCOUNT);
    if(account.type!=='service_account'||typeof account.private_key!=='string'||account.private_key.length>32768||typeof account.client_email!=='string'||!/^[a-zA-Z0-9_.-]+@[a-zA-Z0-9_.-]+\.iam\.gserviceaccount\.com$/.test(account.client_email)||!/^[a-z][a-z0-9-]{4,62}$/.test(account.project_id))throw Error('Invalid configuration');
    if(account.project_id!==input.project_id)return json({error:'Check the configured project',code:'PROJECT_MISMATCH'},409);
    const token=await googleToken(account,send);
    if(expiry<=Math.floor(Date.now()/1000))return json({error:'Call expired',code:'CALL_EXPIRED'},410);
    // Only these four opaque values leave the relay. Caller details, passwords,
    // recordings, URLs and arbitrary notification text are never accepted.
    const data={request_id:d.request_id,device_id:d.device_id,event:d.event,expires:String(expiry)};
    const ttl=Math.max(1,Math.min(30,expiry-Math.floor(Date.now()/1000)));
    const reply=await send(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`,{method:'POST',redirect:'error',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify({message:{token:input.token,data,android:{priority:d.event==='incoming'?'high':'normal',ttl:`${ttl}s`,collapse_key:d.request_id}}}),signal:AbortSignal.timeout(8000)});
    if(reply.ok)return json({ok:true});
    const result=await boundedJson(reply);
    const invalid=reply.status===404 && result?.error?.details?.some(e=>e?.['@type']==='type.googleapis.com/google.firebase.fcm.v1.FcmError'&&e.errorCode==='UNREGISTERED');
    if(invalid)return json({error:'Phone registration expired',code:'UNREGISTERED'},410);
    // A missing project or changed permission is not an invalid phone token.
    let retry=Number(reply.headers.get('Retry-After'));if(!Number.isFinite(retry)||retry<=0)retry=3;retry=Math.max(reply.status===429?60:1,Math.min(retry,300));
    return json({error:'Delivery unavailable',code:'DELIVERY_UNAVAILABLE'},503,{'Retry-After':String(retry)});
  }catch{return json({error:'Delivery unavailable',code:'DELIVERY_UNAVAILABLE'},503)}
}
// Cloudflare passes an ExecutionContext as the third argument; it is not fetch.
export default {fetch(request,env,ctx){return relay(request,env)}};
