import {test} from 'node:test';
import assert from 'node:assert/strict';
import worker,{relay} from './worker.mjs';
const secret='test-only-opaque-relay-secret-no-account';
const project='fixture-project';
const payload=(extra={})=>({project_id:project,token:'fixture-device-token-'+ 'a'.repeat(30),data:{request_id:'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',device_id:'11111111-2222-3333-4444-555555555555',event:'incoming',expires:String(Math.floor(Date.now()/1000)+60)},...extra});
const request=(body,headers={})=>new Request('https://fixture.invalid',{method:'POST',headers:{Authorization:`Bearer ${secret}`,'Content-Type':'application/json',...headers},body:JSON.stringify(body)});
const never=()=>{throw Error('Unexpected external request')};
async function fixture(){
  const key=await crypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',hash:'SHA-256',modulusLength:2048,publicExponent:new Uint8Array([1,0,1])},true,['sign','verify']);
  const pem='-----BEGIN PRIVATE KEY-----\n'+Buffer.from(await crypto.subtle.exportKey('pkcs8',key.privateKey)).toString('base64')+'\n-----END PRIVATE KEY-----\n';
  const env={PBX_RELAY_TOKEN:secret,FCM_SERVICE_ACCOUNT:JSON.stringify({type:'service_account',project_id:project,client_email:'fixture@fixture-project.iam.gserviceaccount.com',private_key:pem})};
  const f={env,key,oauth:0,sends:[],status:200,error:{},pause:0};
  f.send=async(url,options)=>{
    assert.equal(options.redirect,'error');
    if(url==='https://oauth2.googleapis.com/token'){
      f.oauth++;const form=new URLSearchParams(options.body);const jwt=form.get('assertion').split('.');
      assert.equal(form.get('grant_type'),'urn:ietf:params:oauth:grant-type:jwt-bearer');
      assert.equal(await crypto.subtle.verify('RSASSA-PKCS1-v1_5',key.publicKey,Buffer.from(jwt[2],'base64url'),new TextEncoder().encode(jwt[0]+'.'+jwt[1])),true,'OAuth assertion signature is valid');
      const claims=JSON.parse(Buffer.from(jwt[1],'base64url').toString());assert.equal(claims.iss,'fixture@fixture-project.iam.gserviceaccount.com');assert.equal(claims.aud,'https://oauth2.googleapis.com/token');assert.equal(claims.exp-claims.iat,3600);
      if(f.pause)await new Promise(resolve=>setTimeout(resolve,f.pause));
      return Response.json({access_token:'fixture-only-access-token',expires_in:3600});
    }
    assert.equal(url,`https://fcm.googleapis.com/v1/projects/${project}/messages:send`);
    f.sends.push(JSON.parse(options.body));return Response.json(f.status===200?{name:'projects/fixture/messages/1'}:f.error,{status:f.status,headers:f.retry?{'Retry-After':f.retry}:{}});
  };return f;
}
const bare={PBX_RELAY_TOKEN:secret};
test('unauthenticated requests never leave the Worker',async()=>assert.equal((await relay(request({}, {Authorization:'Bearer invalid'}),bare,never)).status,403));
test('browser origins cannot use relay secrets',async()=>assert.equal((await relay(request({}, {Origin:'https://fixture.invalid'}),bare,never)).status,403));
test('GET and JSON-like content types are refused',async()=>{assert.equal((await relay(new Request('https://fixture.invalid'),bare,never)).status,405);assert.equal((await relay(request({}, {'Content-Type':'application/jsonp'}),bare,never)).status,415)});
test('arbitrary call identifiers rejected',async()=>{const p=payload();p.data.request_id='../../secrets';assert.equal((await relay(request(p),bare,never)).status,400)});
test('expired calls do not wake phones or invalidate tokens',async()=>{const p=payload();p.data.expires='1';const r=await relay(request(p),bare,never);assert.equal(r.status,410);assert.equal((await r.json()).code,'CALL_EXPIRED')});
test('large body is bounded without trusting content length',async()=>assert.equal((await relay(request({extra:'a'.repeat(9000)}),bare,never)).status,413));
test('invalid configuration returns no secrets',async()=>{const r=await relay(request(payload()),{...bare,FCM_SERVICE_ACCOUNT:'private-fixture-invalid'},never);assert.equal(r.status,503);assert.equal((await r.json()).error,'Delivery unavailable')});
test('successful delivery signs real RSA assertion and sends only opaque fields',async()=>{const f=await fixture();assert.equal((await relay(request(payload()),f.env,f.send)).status,200);assert.equal(f.oauth,1);assert.equal(f.sends.length,1);const message=f.sends[0].message;assert.deepEqual(Object.keys(message.data).sort(),['device_id','event','expires','request_id']);assert.equal(message.android.priority,'high');assert.equal(message.android.collapse_key,message.data.request_id);assert.ok(Number(message.android.ttl.slice(0,-1))<=30)});
test('simultaneous requests share one OAuth refresh',async()=>{const f=await fixture();f.pause=50;const results=await Promise.all(Array.from({length:8},()=>relay(request(payload()),f.env,f.send)));assert.ok(results.every(r=>r.status===200));assert.equal(f.oauth,1);assert.equal(f.sends.length,8)});
test('same-account key rotation invalidates cached access token',async()=>{const first=await fixture();await relay(request(payload()),first.env,first.send);const rotated=await fixture();assert.equal((await relay(request(payload()),rotated.env,rotated.send)).status,200);assert.equal(rotated.oauth,1)});
test('mismatched project never makes an external request',async()=>{const f=await fixture();const r=await relay(request(payload({project_id:'another-project'})),f.env,never);assert.equal(r.status,409);assert.equal((await r.json()).code,'PROJECT_MISMATCH')});
test('project-not-found HTTP404 preserves valid phone registration',async()=>{const f=await fixture();f.status=404;f.error={error:{status:'NOT_FOUND',message:'Project does not exist'}};const r=await relay(request(payload()),f.env,f.send);assert.equal(r.status,503);assert.equal((await r.json()).code,'DELIVERY_UNAVAILABLE')});
test('only typed UNREGISTERED invalidates a token',async()=>{const f=await fixture();f.status=404;f.error={error:{details:[{'@type':'type.googleapis.com/google.firebase.fcm.v1.FcmError',errorCode:'UNREGISTERED'}]}};const r=await relay(request(payload()),f.env,f.send);assert.equal(r.status,410);assert.equal((await r.json()).code,'UNREGISTERED')});
test('generic invalid argument is not treated as an unregistered phone',async()=>{const f=await fixture();f.status=400;f.error={error:{status:'INVALID_ARGUMENT',details:[{'@type':'type.googleapis.com/google.rpc.BadRequest'}]}};assert.equal((await relay(request(payload()),f.env,f.send)).status,503)});
test('quota response requires at least one minute backoff',async()=>{const f=await fixture();f.status=429;f.retry='2';const r=await relay(request(payload()),f.env,f.send);assert.equal(r.status,503);assert.equal(r.headers.get('Retry-After'),'60')});
test('redirect response cannot become success or invalidate a device',async()=>{const f=await fixture();f.status=302;assert.equal((await relay(request(payload()),f.env,f.send)).status,503)});
test('ended notification replaces only matching opaque call and uses normal priority',async()=>{const f=await fixture();const p=payload();p.data.event='ended';p.data.expires=String(Math.floor(Date.now()/1000)+5);assert.equal((await relay(request(p),f.env,f.send)).status,200);const m=f.sends[0].message;assert.equal(m.android.priority,'normal');assert.equal(m.android.collapse_key,p.data.request_id);assert.ok(Number(m.android.ttl.slice(0,-1))<=5)});
test('arbitrary URL or notification body is rejected',async()=>{const f=await fixture();assert.equal((await relay(request(payload({url:'https://not-allowed.invalid'})),f.env,never)).status,400);const p=payload();p.data.caller_name='Private';assert.equal((await relay(request(p),f.env,never)).status,400)});
test('downstream error text is never echoed',async()=>{const f=await fixture();f.status=500;f.error={error:{message:'private-fixture-error-with-token'}};const r=await relay(request(payload()),f.env,f.send);assert.ok(!(await r.text()).includes('private-fixture-error'))});
test('default Cloudflare fetch signature does not treat ExecutionContext as fetch',async()=>{const f=await fixture();const original=globalThis.fetch;globalThis.fetch=f.send;try{assert.equal((await worker.fetch(request(payload()),f.env,{waitUntil(){throw Error('Unexpected background work')}})).status,200)}finally{globalThis.fetch=original}});
test('oversized provider response fails without exposing content',async()=>{const f=await fixture();const send=async(url,options)=>url.endsWith('/token')?f.send(url,options):new Response('x'.repeat(70000),{status:500});const r=await relay(request(payload()),f.env,send);assert.equal(r.status,503);assert.equal((await r.json()).error,'Delivery unavailable')});
async function webFixture(){
  const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const encode=bytes=>Buffer.from(bytes).toString('base64url');
  const pub=encode(await crypto.subtle.exportKey('raw',keys.publicKey));
  const header=encode(JSON.stringify({alg:'ES256',typ:'JWT'})),claims=encode(JSON.stringify({aud:'https://fcm.googleapis.com',exp:Math.floor(Date.now()/1000)+3600,sub:'mailto:fixture@example.invalid'}));
  const signed=header+'.'+claims,sig=encode(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},keys.privateKey,new TextEncoder().encode(signed)));
  return {transport:'webpush',endpoint:'https://fcm.googleapis.com/fcm/send/'+'b'.repeat(40),body:'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN',authorization:`vapid t=${signed}.${sig}, k=${pub}`,ttl:30,urgency:'high'};
}
test('encrypted Web Push forwards with no Firebase service account',async()=>{const p=await webFixture();let calls=0;const r=await relay(request(p),bare,async(url,options)=>{calls++;assert.equal(url,p.endpoint);assert.equal(options.redirect,'error');assert.equal(options.headers['Content-Encoding'],'aes128gcm');assert.equal(options.headers.Authorization,p.authorization);assert.equal(Buffer.from(options.body).toString('base64url'),p.body);return new Response(null,{status:201})});assert.equal(r.status,200);assert.equal(calls,1)});
test('encrypted relay refuses private and lookalike endpoint hosts',async()=>{const p=await webFixture();for(const endpoint of ['https://127.0.0.1/fcm/send/'+'b'.repeat(40),'https://fcm.googleapis.com.evil.invalid/fcm/send/'+'b'.repeat(40),'https://fcm.googleapis.com/v1/projects/anything/messages:send'])assert.equal((await relay(request({...p,endpoint}),bare,never)).status,400)});
test('encrypted relay refuses forged VAPID signatures',async()=>{const p=await webFixture();p.authorization=p.authorization.replace(/t=([^,]+)/,(_,jwt)=>'t='+jwt.slice(0,-2)+'xx');assert.equal((await relay(request(p),bare,never)).status,400)});
test('encrypted relay bounds TTL and rejects arbitrary forwarded headers',async()=>{const p=await webFixture();assert.equal((await relay(request({...p,ttl:61}),bare,never)).status,400);assert.equal((await relay(request({...p,headers:{Authorization:'arbitrary'}}),bare,never)).status,400)});
test('expired encrypted subscription is distinguished from provider failure',async()=>{const p=await webFixture();const gone=await relay(request(p),bare,async()=>new Response(null,{status:410}));assert.equal(gone.status,410);assert.equal((await gone.json()).code,'UNREGISTERED');const failed=await relay(request(p),bare,async()=>new Response(null,{status:403}));assert.equal(failed.status,503);assert.equal((await failed.json()).code,'DELIVERY_UNAVAILABLE')});
test('encrypted relay does not follow redirects',async()=>{const p=await webFixture();const r=await relay(request(p),bare,async(_url,options)=>{assert.equal(options.redirect,'error');return new Response(null,{status:302,headers:{Location:'https://127.0.0.1/private'}})});assert.equal(r.status,503)});
