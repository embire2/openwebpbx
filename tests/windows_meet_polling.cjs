// Actual media-wait source with explicit asynchronous page adapters only.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {performance}=require('node:perf_hooks');
let checks=0;
function check(value){assert.ok(value);checks++;}
const source=fs.readFileSync(path.join(__dirname,'windows-meet-browser.cjs'),'utf8');
const start=source.indexOf('async function proof(page) {'),end=source.indexOf('\nasync function proofFailure(error)',start);
check(start>=0&&end>start);
const timers=new Set();
const setOwnedTimeout=(callback,delay)=>{let id;id=setTimeout(()=>{timers.delete(id);callback();},delay);timers.add(id);return id;};
const clearOwnedTimeout=id=>{clearTimeout(id);timers.delete(id);};
const sandbox={performance,setTimeout:setOwnedTimeout,clearTimeout:clearOwnedTimeout,proofPage:undefined};
const helpers=vm.runInNewContext('(()=>{'+source.slice(start,end)+';return {proof,pollProof};})()',sandbox);
let mediaAccept,mediaTimeout,mediaPage;
const capture=vm.runInNewContext('('+source.slice(start,source.indexOf('\nasync function pollProof',start))+')',{
 proofPage:undefined,pollProof(page,accept,timeout){mediaAccept=accept;mediaTimeout=timeout;mediaPage=page;}
});
const mute=source.match(/await pollProof\(host,(p=>[^;]+),15000\);/);check(!!mute);
const muteAccept=vm.runInNewContext('('+mute[1]+')');
const good=()=>({connected:true,decoded_frames:10,video_colors:9,tone_ratio:.65001,power:.00001001,codecs:['video/VP8']});
async function refused(page,accept,timeout,expected){
 let caught;try{await helpers.pollProof(page,accept,timeout);}catch(error){caught=error;}
 check(expected?caught===expected:caught?.name==='TimeoutError');check(timers.size===0);return caught;
}
(async()=>{
 await capture('owned-page');check(mediaPage==='owned-page');check(mediaTimeout===45000);
 check(mediaAccept(good())===true);check(muteAccept({connected:true,power:.0000009})===true);
 for(const value of [undefined,null,{connected:false},{...good(),decoded_frames:9},{...good(),video_colors:8},{...good(),tone_ratio:.65},{...good(),power:.00001}]){
  check(!mediaAccept(value));let calls=0;await refused({async evaluate(){calls++;return value;}},mediaAccept,15);check(calls>=1);
 }
 for(const value of [undefined,{connected:false,power:0},{connected:true,power:.000001},{connected:true,power:.2}]){
  check(!muteAccept(value));await refused({async evaluate(){return value;}},muteAccept,15);
 }
 let calls=0,active=0,maxActive=0;const expected=good();
 const answer=await helpers.pollProof({async evaluate(){calls++;active++;maxActive=Math.max(maxActive,active);await new Promise(resolve=>setTimeout(resolve,2));active--;return calls<3?{connected:false}:expected;}},mediaAccept,1000);
 check(answer===expected);check(calls===3);check(maxActive===1&&active===0);check(timers.size===0);
 const error=new TypeError('PRIVATE_PAGE_REJECTION');calls=0;
 await refused({async evaluate(){calls++;throw error;}},mediaAccept,100,error);check(calls===1);
 const acceptError=new Error('PRIVATE_ACCEPT_REJECTION');await refused({async evaluate(){return good();}},()=>{throw acceptError;},100,acceptError);
 const beginning=performance.now();calls=0;
 await refused({evaluate(){calls++;return new Promise(()=>{});}},mediaAccept,25);check(calls===1);check(performance.now()-beginning<500);
 for(const timeout of [0,-1,NaN,Infinity,'45',45001]){
  let evaluated=false,caught;try{await helpers.pollProof({evaluate(){evaluated=true;}},mediaAccept,timeout);}catch(error){caught=error;}
  check(caught?.name==='RangeError');check(!evaluated);check(timers.size===0);
 }
 console.log(JSON.stringify({schema:1,state:'passed',checks,actual_wait_source:true,asynchronous_page_adapters:true,media_deadline_ms:mediaTimeout,mute_deadline_ms:15000,actual_browser_or_media_qualified:false,network_or_server_changed:false}));
})().catch(error=>{for(const timer of timers)clearTimeout(timer);console.error(error);process.exitCode=1;});
