// Isolated native browser offer construction; this never qualifies PBX services.
'use strict';
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),crypto=require('node:crypto');
const syntheticHash='cb471332f3ad7eee5f4da5f83837859e1ce7b2833c068a532c657e727c11c2b5';
const sipHash='080a71b32938adc31619c741e5dc476763a05cb53121d0cb8e61ee7790f47641';
const digest=value=>crypto.createHash('sha256').update(value).digest('hex');
function syntheticSource(source){
 const begin=source.indexOf('function syntheticMedia(frequency) {'),end=source.indexOf('async function proof(page) {');
 if(begin<0||end<=begin)throw Error('source');const value=source.slice(begin,end);
 if(digest(value)!==syntheticHash)throw Error('binding');return value;
}
function validCase(row){
 const fields=['custom_python_user_agent','state','elapsed_ms','content_type_sdp','audio_mline','video_mline','vp8_offer','local_description','signaling_state','ice_gathering_state','local_live_tracks','phase'];
 if(!row||typeof row!=='object'||Array.isArray(row)||Object.keys(row).length!==fields.length||fields.some(key=>!Object.hasOwn(row,key)))return false;
 if(['custom_python_user_agent','content_type_sdp','audio_mline','video_mline','vp8_offer','local_description'].some(key=>typeof row[key]!=='boolean'))return false;
 return ['passed','failed'].includes(row.state)&&Number.isInteger(row.elapsed_ms)&&row.elapsed_ms>=0&&row.elapsed_ms<=20000&&Number.isInteger(row.local_live_tracks)&&row.local_live_tracks>=0&&row.local_live_tracks<=2&&['stable','have-local-offer','have-remote-offer','have-local-pranswer','have-remote-pranswer','closed','unavailable'].includes(row.signaling_state)&&['new','gathering','complete','unavailable'].includes(row.ice_gathering_state)&&['complete','get_offer','deadline','exception'].includes(row.phase);
}
async function main(){
 const destination=process.argv[2],dependencies=process.argv[3],result={schema:1,state:'failed',scope:'isolated Windows browser offer; no PBX or SIP connection',release_eligible:false,owner_transaction_eligible:false,cases:[],owned_listener_closed:true};
 let browser,server;
 try{
  if(process.platform!=='win32'||process.env.GITHUB_ACTIONS!=='true'||process.env.RUNNER_ENVIRONMENT!=='github-hosted'||process.env.GITHUB_REPOSITORY!=='embire2/openwebpbx')throw Error('platform');
  const sip=fs.readFileSync(path.join(__dirname,'../app/pbx_meet/vendor/sip.js'));if(digest(sip)!==sipHash)throw Error('binding');
  const source=syntheticSource(fs.readFileSync(path.join(__dirname,'windows-meet-browser.cjs'),'utf8'));
  const {chromium}=require(path.join(dependencies,'node_modules/playwright-core'));
  server=http.createServer((request,response)=>{if(request.url==='/sip.js'){response.setHeader('Content-Type','text/javascript');response.end(sip);}else if(request.url==='/'){response.setHeader('Content-Type','text/html');response.end('<!doctype html><title>Owned isolated offer</title><button id="go">Construct local offer</button>');}else{response.statusCode=404;response.end();}});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));result.owned_listener_closed=false;
  browser=await chromium.launch({channel:'msedge',headless:true,args:['--autoplay-policy=no-user-gesture-required','--disable-features=WebRtcHideLocalIpsWithMdns']});
  for(const custom of [false,true]){
   const context=await browser.newContext(custom?{userAgent:'Python-urllib/3.13'}:{}),page=await context.newPage();
   await context.addInitScript({content:source+'\nsyntheticMedia(550);'});await page.goto('http://127.0.0.1:'+server.address().port+'/');
   await page.evaluate(custom=>{
    document.getElementById('go').onclick=async()=>{
     let call,timer,record;const start=performance.now();let phase='get_offer';
     try{
      const {UserAgent,Inviter}=await import('/sip.js');
      const ua=new UserAgent({uri:UserAgent.makeURI('sip:fictional@fixture.invalid'),authorizationUsername:'fictional',authorizationPassword:'fictional-not-networked',transportOptions:{server:'wss://fixture.invalid/no-network'},logBuiltinEnabled:false,logConfiguration:false,userAgentString:'OpenWebPBX Meet',sessionDescriptionHandlerFactoryOptions:{iceGatheringTimeout:3000,peerConnectionConfiguration:{iceServers:[]}}});
      const constraints={audio:{echoCancellation:true,noiseSuppression:true},video:{width:{ideal:640},height:{ideal:360},frameRate:{ideal:15}}};
      call=new Inviter(ua,UserAgent.makeURI('sip:room@fixture.invalid'),{sessionDescriptionHandlerOptions:{constraints,offerOptions:{offerToReceiveVideo:true}}});
      const offer=await Promise.race([call.getOffer({sessionDescriptionHandlerOptions:call.sessionDescriptionHandlerOptions}),new Promise((_,reject)=>{timer=setTimeout(()=>{phase='deadline';reject(Error('deadline'));},12000);})]);
      record={content_type_sdp:offer.contentType==='application/sdp',audio_mline:offer.content.includes('\nm=audio '),video_mline:offer.content.includes('\nm=video '),vp8_offer:offer.content.includes('VP8/90000')};phase='complete';
     }catch{record={content_type_sdp:false,audio_mline:false,video_mline:false,vp8_offer:false};if(phase!=='deadline')phase='exception';}
     finally{
      clearTimeout(timer);const pc=window.conferenceQA.pcs.at(-1);
      const row={custom_python_user_agent:custom,state:phase==='complete'?'passed':'failed',elapsed_ms:Math.round(performance.now()-start),...record,local_description:!!pc?.localDescription,signaling_state:pc?.signalingState||'unavailable',ice_gathering_state:pc?.iceGatheringState||'unavailable',local_live_tracks:pc?.getSenders().filter(sender=>sender.track?.readyState==='live').length||0,phase};
      for(const item of window.conferenceQA.pcs){for(const sender of item.getSenders())sender.track?.stop();item.close();}clearInterval(window.conferenceQA.animation);window.conferenceQA.video?.getTracks().forEach(track=>track.stop());window.conferenceQA.oscillator?.stop();await window.conferenceQA.audio?.close();window.offerQualification=row;
     }
    };
   },custom);
   await page.getByRole('button',{name:'Construct local offer',exact:true}).click();await page.waitForFunction(()=>!!window.offerQualification,null,{timeout:17000});
   const row=await page.evaluate(()=>window.offerQualification);if(!validCase(row))throw Error('report');result.cases.push(row);await context.close();
  }
  result.sip_binding=true;result.synthetic_binding=true;
  result.state=result.cases.length===2&&result.cases.every(row=>row.state==='passed'&&row.content_type_sdp&&row.audio_mline&&row.video_mline&&row.vp8_offer&&row.local_description&&row.local_live_tracks===2)?'passed':'failed';
 }catch{result.state='failed';result.fixture_error=true;}
 finally{
  await browser?.close();if(server){await new Promise(resolve=>server.close(resolve));result.owned_listener_closed=!server.listening;}
  if(!result.owned_listener_closed)result.state='failed';fs.mkdirSync(path.dirname(destination),{recursive:true});fs.writeFileSync(destination,JSON.stringify(result,null,2)+'\n');process.exitCode=result.state==='passed'?0:1;
 }
}
module.exports={syntheticSource,validCase,syntheticHash,sipHash};
if(require.main===module)main();
