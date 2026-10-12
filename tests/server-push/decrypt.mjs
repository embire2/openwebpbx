// Independent Node/OpenSSL receiver for the server's RFC8291/RFC8292 output.
import {createECDH,hkdfSync,createDecipheriv,createPublicKey,verify} from 'node:crypto';
import assert from 'node:assert/strict';
let input='';for await(const chunk of process.stdin)input+=chunk;const fixture=JSON.parse(input);
function decrypt(wire,authorization){
const salt=wire.subarray(0,16),server=wire.subarray(21,86),encrypted=wire.subarray(86,-16),tag=wire.subarray(-16);
assert.equal(wire.readUInt32BE(16),4096);assert.equal(wire[20],65);
const receiver=createECDH('prime256v1');receiver.setPrivateKey(Buffer.from(fixture.receiver,'base64url'));const shared=receiver.computeSecret(server),publicKey=receiver.getPublicKey();
const ikm=hkdfSync('sha256',shared,Buffer.from(fixture.auth,'base64url'),Buffer.concat([Buffer.from('WebPush: info\0'),publicKey,server]),32);
const cek=hkdfSync('sha256',ikm,salt,Buffer.from('Content-Encoding: aes128gcm\0'),16),nonce=hkdfSync('sha256',ikm,salt,Buffer.from('Content-Encoding: nonce\0'),12);
const cipher=createDecipheriv('aes-128-gcm',cek,nonce);cipher.setAuthTag(tag);const plain=Buffer.concat([cipher.update(encrypted),cipher.final()]);assert.equal(plain.at(-1),2);
const message=JSON.parse(plain.subarray(0,-1).toString());assert.equal(message.request_id,fixture.request);assert.equal(message.device_id,fixture.device);assert.equal(message.event,fixture.event??'incoming');assert.deepEqual(Object.keys(message).sort(),['device_id','event','expires','request_id']);
const [jwt,pub]=authorization.slice(8).split(', k='),parts=jwt.split('.'),point=Buffer.from(pub,'base64url'),key=createPublicKey({key:{kty:'EC',crv:'P-256',x:point.subarray(1,33).toString('base64url'),y:point.subarray(33).toString('base64url')},format:'jwk'});
assert.equal(JSON.parse(Buffer.from(parts[0],'base64url')).alg,'ES256');assert.equal(JSON.parse(Buffer.from(parts[1],'base64url')).aud,'https://fcm.googleapis.com');assert.equal(verify('sha256',Buffer.from(parts[0]+'.'+parts[1]),{key,dsaEncoding:'ieee-p1363'},Buffer.from(parts[2],'base64url')),true);
}
if(fixture.relay){
  // Execute the real Cloudflare code with no Cloudflare account, Google service
  // account or external request. Its downstream ciphertext must decrypt here.
  const {relay}=await import('../../integrations/cloudflare-push/worker.mjs');
  let delivered=0;
  const response=await relay(new Request('https://fixture-push.fixture-account.workers.dev',{method:'POST',headers:{Authorization:fixture.authorization,'Content-Type':'application/json'},body:fixture.body}),{PBX_RELAY_TOKEN:fixture.relay},async(endpoint,options)=>{
    const original=JSON.parse(fixture.body);assert.equal(endpoint,original.endpoint);assert.equal(options.redirect,'error');assert.equal(options.headers['Content-Encoding'],'aes128gcm');assert.equal(options.headers.Urgency,(fixture.event??'incoming')==='incoming'?'high':'normal');assert.equal(options.headers.TTL,String(original.ttl));
    assert.ok(!fixture.body.includes(fixture.request)&&!fixture.body.includes(fixture.device),'Opaque call data is encrypted before Cloudflare');
    assert.deepEqual(Buffer.from(options.body),Buffer.from(original.body,'base64url'));decrypt(Buffer.from(options.body),options.headers.Authorization);delivered++;
    return new Response(null,{status:fixture.providerStatus??201,headers:fixture.providerRetry?{'Retry-After':fixture.providerRetry}:{}});
  });
  console.log(JSON.stringify({status:response.status,body:await response.text(),retryAfter:response.headers.get('Retry-After'),delivered}));
}else{
  decrypt(Buffer.from(fixture.body,'base64'),fixture.authorization);
  console.log('PASS: independent Web Push decryption and VAPID verification');
}
