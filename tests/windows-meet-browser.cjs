// Actual product UI, IIS/WSS, DTLS/SRTP and decoded browser media on an owned runner.
const fs = require('node:fs');
const path = require('node:path');
const signaling = require('./windows-meet-signaling.cjs');
const pathDiagnostics = require('./windows-meet-path-diagnostics.cjs');
const browserFailure = require('./windows-meet-failure.cjs');
if(process.platform !== 'win32' || process.env.OPENWEB_WINDOWS_NATIVE_TEST !== '1' || process.env.GITHUB_ACTIONS !== 'true' || process.env.RUNNER_ENVIRONMENT !== 'github-hosted' || process.env.GITHUB_REPOSITORY !== 'embire2/openwebpbx') throw Error('An explicitly disposable Windows runner is required.');
const settings = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const {chromium} = require(path.join(settings.dependencies, 'node_modules', 'playwright-core'));
if(!/^https:\/\/windowsqa\.example\.invalid(?::[0-9]+)?$/.test(settings.origin) || !Array.isArray(settings.cookies) || typeof settings.userAgent !== 'string' || !settings.userAgent.length || settings.userAgent.length > 512 || /[\x00-\x1f\x7f]/.test(settings.userAgent)) throw Error('The owned qualification HTTPS origin is required.');
const privateDirectory=path.dirname(settings.report),normalized=value=>typeof value==='string'?path.resolve(value).toLowerCase():'';
if(!settings.pathProbe||normalized(settings.pathProbe.php)!==normalized('C:/OpenWebPBX/php/php.exe')||normalized(settings.pathProbe.powershell)!==normalized(path.join(process.env.SystemRoot||'C:/Windows','System32/WindowsPowerShell/v1.0/powershell.exe'))||normalized(settings.pathProbe.wssScript)!==normalized(path.join(__dirname,'windows-meet-wss-path.ps1'))||normalized(settings.pathProbe.fixtureScript)!==normalized(path.join(__dirname,'windows-native-fixture.php'))||normalized(settings.pathProbe.fixtureInput)!==normalized(path.join(privateDirectory,'../input.json'))||normalized(settings.pathProbe.caFile)!==normalized(path.join(privateDirectory,'fixture-root.pem')))throw Error('The exact owned read-only diagnostic fixture is required.');
const evidence = path.dirname(process.argv[2]);
const checks = [];
let hostBrowser, guestBrowser, owner, host, guest, meetingCreated = false;
let restoredMeetingId;
if(settings.restoredLedger && normalized(settings.restoredLedger)!==normalized(path.join(privateDirectory,'restored-meeting.private.json')))throw Error('Exact restored meeting ledger required.');
function saveRestoredMeeting(id){
  if(typeof id!=='string'||!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(id))throw Error('One newly created meeting UUID is required.');
  const fd=fs.openSync(settings.restoredLedger,'wx',0o600);
  try{fs.writeFileSync(fd,JSON.stringify({schema:1,meeting_uuid:id,subject:settings.subject}));fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
  restoredMeetingId=id;
}

let phase = 'browser_start';
let ownerPage;
let hostSignaling, guestSignaling;
let beforePath=pathDiagnostics.defaults(),afterPath,hostSecret=()=>undefined,guestSecret=()=>undefined;
let proofPage;
const mediaBooleans=['observed','connected','remote_audio_live','remote_video_live','local_audio_live','local_video_live','vp8_decoding','probe_error'];
const mediaIntegers=['decoded_frames','encoded_frames','inbound_audio_packets','outbound_audio_packets','inbound_video_packets','outbound_video_packets','video_colors'];
const mediaEnums={connection_state:['new','connecting','connected','disconnected','failed','closed','unavailable'],ice_state:['new','checking','connected','completed','disconnected','failed','closed','unavailable'],visibility:['visible','hidden','prerender','unavailable'],audio_context:['running','suspended','closed','interrupted','unavailable'],ui_state:['connected','connecting','waiting','ended','rejected','connect_error','permission_error','device_error','unavailable','other']};
function closedMediaFields(record) {
  const fields=[...mediaBooleans,...mediaIntegers,...Object.keys(mediaEnums),'tone_ratio','power'];
  if(!record||typeof record!=='object'||Array.isArray(record)||Object.keys(record).length!==fields.length||fields.some(name=>!Object.hasOwn(record,name))) return null;
  if(mediaBooleans.some(name=>typeof record[name]!=='boolean')||mediaIntegers.some(name=>!Number.isInteger(record[name])||record[name]<0||record[name]>(name==='video_colors'?14400:2147483647))||Object.entries(mediaEnums).some(([name,values])=>!values.includes(record[name]))||['tone_ratio','power'].some(name=>typeof record[name]!=='number'||!Number.isFinite(record[name])||record[name]<0||record[name]>1)) return null;
  return Object.fromEntries(fields.map(name=>[name,record[name]]));
}
function unavailableMediaFields() {
  return {...Object.fromEntries(mediaBooleans.map(name=>[name,false])),...Object.fromEntries(mediaIntegers.map(name=>[name,0])),...Object.fromEntries(Object.keys(mediaEnums).map(name=>[name,'unavailable'])),tone_ratio:0,power:0};
}
async function mediaFields(page) {
  if(!page)return unavailableMediaFields();
  let timer;
  try{const value=await Promise.race([page.evaluate(()=>window.conferenceQA?.diagnostic?.()),new Promise(resolve=>{timer=setTimeout(()=>resolve(null),3000);})]);return closedMediaFields(value)||unavailableMediaFields();}catch{return unavailableMediaFields();}finally{clearTimeout(timer);}
}
function requireFact(value, name) {if(!value) throw Error(name); checks.push(name);}
async function ownerPageFields(page, response) {
  const current = new URL(page.url());
  const route = current.pathname === '/app/pbx_meet/' || current.pathname === '/app/pbx_meet/index.php' ? 'meet' : current.pathname === '/login.php' ? 'login' : current.pathname === '/logout.php' ? 'logout' : current.pathname === '/core/desktop/' ? 'desktop' : 'other';
  return {http_status:response ? response.status() : 0, route,
    login_form:await page.locator('input[name="password"]').count()>0,
    heading:await page.getByRole('heading',{name:'Meet',exact:true}).isVisible(),
    same_origin:current.origin===settings.origin,
    user_agent_matches:await page.evaluate(expected=>navigator.userAgent===expected,settings.userAgent)};
}
async function snapshot(page, name) {fs.writeFileSync(path.join(evidence, `${name}.private.txt`), await page.locator('body').ariaSnapshot());}
function syntheticMedia(frequency) {
  if(!navigator.mediaDevices) return;
  const NativePC = window.RTCPeerConnection;
  const qa = window.conferenceQA = {pcs:[], frequency};
  window.RTCPeerConnection = class extends NativePC {constructor(...args) {super(...args); qa.pcs.push(this);}};
  navigator.mediaDevices.getUserMedia = async constraints => {
    if(!qa.audio) {
      const audio = qa.audio = new AudioContext();
      const oscillator = audio.createOscillator(); oscillator.frequency.value = frequency;
      const gain = audio.createGain(); gain.gain.value = .25;
      const destination = qa.destination = audio.createMediaStreamDestination();
      oscillator.connect(gain).connect(destination); oscillator.start(); qa.oscillator = oscillator;
      const canvas = document.createElement('canvas'); canvas.width=640; canvas.height=360;
      const pen = canvas.getContext('2d'); let tick=0;
      qa.animation = setInterval(() => {for(let y=0;y<6;y++)for(let x=0;x<8;x++){pen.fillStyle=`hsl(${(tick+x*39+y*23+frequency)%360} 90% 55%)`;pen.fillRect(x*80,y*60,80,60);}tick+=5;},100);
      qa.video = canvas.captureStream(10);
    }
    await qa.audio.resume();
    return new MediaStream([...(constraints.audio?qa.destination.stream.getAudioTracks().map(track=>track.clone()):[]),...(constraints.video?qa.video.getVideoTracks().map(track=>track.clone()):[])]);
  };
  qa.proof = async () => {
    qa.proofOperation='peer_lookup';
    const pc = qa.pcs.findLast(candidate => candidate.connectionState === 'connected');
    if(!pc) return {connected:false,states:qa.pcs.map(candidate=>candidate.connectionState)};
    qa.proofOperation='stats';
    let decoded=0, encoded=0; const codecs=[]; const stats=await pc.getStats();
    for(const row of stats.values()){
      if(row.type==='inbound-rtp' && row.kind==='video'){decoded+=row.framesDecoded||0; codecs.push(stats.get(row.codecId)?.mimeType);}
      if(row.type==='outbound-rtp' && row.kind==='video')encoded+=row.framesEncoded||0;
    }
    const remote=document.getElementById('remote');
    if(!qa.analyser && remote.srcObject?.getAudioTracks().length){
      qa.proofOperation='analyser_create';
      qa.analyser=qa.audio.createAnalyser();qa.analyser.fftSize=4096;qa.analyser.smoothingTimeConstant=0;
      qa.proofOperation='analyser_source';
      const source=qa.audio.createMediaStreamSource(new MediaStream(remote.srcObject.getAudioTracks()));
      qa.proofOperation='analyser_connect';source.connect(qa.analyser);
      qa.proofOperation='analyser_output';
      const silent=qa.audio.createGain();silent.gain.value=0;qa.analyser.connect(silent).connect(qa.audio.destination);
    }
    let total=0, band=0, power=0;
    if(qa.analyser){
      qa.proofOperation='spectrum';
      const bins=new Float32Array(qa.analyser.frequencyBinCount), samples=new Float32Array(qa.analyser.fftSize);
      qa.analyser.getFloatFrequencyData(bins);qa.analyser.getFloatTimeDomainData(samples);
      for(let i=2;i<bins.length;i++){const energy=10**(bins[i]/10), hz=i*qa.audio.sampleRate/qa.analyser.fftSize;total+=energy;if(Math.abs(hz-(frequency===550?770:550))<35)band+=energy;}
      for(const sample of samples)power+=sample*sample;power/=samples.length;
    }
    qa.proofOperation='canvas_create';
    const canvas=document.createElement('canvas');canvas.width=160;canvas.height=90;let colors=0;
    if(remote.readyState>=2){const pen=canvas.getContext('2d');qa.proofOperation='canvas_draw';pen.drawImage(remote,0,0,160,90);qa.proofOperation='canvas_read';const pixels=pen.getImageData(0,0,160,90).data,set=new Set();for(let i=0;i<pixels.length;i+=28)set.add(pixels.slice(i,i+3).join(','));colors=set.size;}
    qa.proofOperation='complete';
    return {connected:true,decoded_frames:decoded,encoded_frames:encoded,codecs,video_colors:colors,tone_ratio:total?band/total:0,power};
  };
  qa.diagnostic = async () => {
    const pc=qa.pcs.findLast(candidate=>candidate.connectionState==='connected')||qa.pcs.at(-1);
    const live=tracks=>!!tracks?.some(track=>track.readyState==='live'&&track.enabled&&!track.muted);
    const remote=document.getElementById('remote');
    const result={observed:true,connected:pc?.connectionState==='connected',connection_state:pc?.connectionState||'unavailable',ice_state:pc?.iceConnectionState||'unavailable',visibility:document.visibilityState,audio_context:qa.audio?.state||'unavailable',decoded_frames:0,encoded_frames:0,inbound_audio_packets:0,outbound_audio_packets:0,inbound_video_packets:0,outbound_video_packets:0,video_colors:0,tone_ratio:0,power:0,remote_audio_live:live(remote?.srcObject?.getAudioTracks()),remote_video_live:live(remote?.srcObject?.getVideoTracks()),local_audio_live:live(pc?.getSenders().map(sender=>sender.track).filter(track=>track?.kind==='audio')),local_video_live:live(pc?.getSenders().map(sender=>sender.track).filter(track=>track?.kind==='video')),vp8_decoding:false,probe_error:false};
    const text=document.getElementById('status')?.textContent;
    const statuses={'Connected. Your microphone and camera are controlled by the buttons below.':'connected','Connecting to your meeting…':'connecting','You are in the waiting room. The host will admit you.':'waiting','Waiting for the host to start the meeting.':'waiting','You have left the meeting. You can close this tab.':'ended','Your meeting call ended. Reopen your invitation to join again.':'ended','Could not join the meeting. Ask the host to check that it is open.':'rejected','Could not connect to the meeting. Check your network and try again.':'connect_error','Microphone or camera permission was declined. Allow it in your browser, then try again.':'permission_error','That microphone or camera is unavailable. Choose audio or another device.':'device_error'};
    result.ui_state=text===undefined?'unavailable':Object.hasOwn(statuses,text)?statuses[text]:'other';
    if(pc)try{
      const stats=await pc.getStats();const codecs=[];
      for(const row of stats.values()){
        if(row.type==='inbound-rtp'&&row.kind==='audio')result.inbound_audio_packets+=row.packetsReceived||0;
        if(row.type==='outbound-rtp'&&row.kind==='audio')result.outbound_audio_packets+=row.packetsSent||0;
        if(row.type==='inbound-rtp'&&row.kind==='video'){result.inbound_video_packets+=row.packetsReceived||0;result.decoded_frames+=row.framesDecoded||0;codecs.push(stats.get(row.codecId)?.mimeType);}
        if(row.type==='outbound-rtp'&&row.kind==='video'){result.outbound_video_packets+=row.packetsSent||0;result.encoded_frames+=row.framesEncoded||0;}
      }
      result.vp8_decoding=codecs.length>0&&codecs.every(value=>value==='video/VP8');
    }catch{result.probe_error=true;}
    try{const proof=await qa.proof();if(proof.connected){result.video_colors=proof.video_colors;result.tone_ratio=proof.tone_ratio;result.power=proof.power;}}catch{result.probe_error=true;}
    return result;
  };
}
async function proof(page) {
  proofPage=page;
  return pollProof(page,p=>p?.connected&&p.decoded_frames>=10&&p.video_colors>8&&p.tone_ratio>.65&&p.power>0.00001,45000);
}
async function pollProof(page,accept,timeout) {
  // The pinned driver's synchronous poller treats a Promise as truthy.
  // Await each proof before testing its media values; keep evaluations serial.
  if(!Number.isInteger(timeout)||timeout<1||timeout>45000)throw new RangeError('A bounded media observation deadline is required.');
  const deadline=performance.now()+timeout;
  const expired=()=>{const error=new Error('The required decoded media observation did not arrive.');error.name='TimeoutError';return error;};
  while(true){
    const remaining=deadline-performance.now();if(remaining<=0)throw expired();
    let timer,record;
    try{record=await Promise.race([page.evaluate(()=>window.conferenceQA?.proof()),new Promise((_,reject)=>{timer=setTimeout(()=>reject(expired()),remaining);})]);}finally{clearTimeout(timer);}
    if(performance.now()>=deadline)throw expired();
    if(accept(record))return record;
    await new Promise(resolve=>setTimeout(resolve,Math.min(100,deadline-performance.now())));
  }
}
async function proofFailure(error){
 let operation='none',timer;
 try{if(proofPage&&['decoded_media','unmute'].includes(phase))operation=await Promise.race([proofPage.evaluate(()=>window.conferenceQA?.proofOperation),new Promise(resolve=>{timer=setTimeout(()=>resolve('none'),3000);})]);}catch{}finally{clearTimeout(timer);}
 return browserFailure.fields(error,operation);
}
(async()=>{
  let failure;
  try{
    beforePath=await pathDiagnostics.observe(settings,'before');
    requireFact(pathDiagnostics.roundTrips(beforePath),'backend and IIS frontend return correlated small and delayed-fragmented SIP responses before media');
    const launch={channel:'msedge',headless:true,args:['--autoplay-policy=no-user-gesture-required','--disable-features=WebRtcHideLocalIpsWithMdns']};
    hostBrowser=await chromium.launch(launch);guestBrowser=await chromium.launch(launch);
    const hostContext=await hostBrowser.newContext({ignoreHTTPSErrors:false,userAgent:settings.userAgent});
    const guestContext=await guestBrowser.newContext({ignoreHTTPSErrors:false});
    await hostContext.addInitScript(syntheticMedia,550);await guestContext.addInitScript(syntheticMedia,770);
    await hostContext.addCookies(settings.cookies);
    phase='owner_page';owner=await hostContext.newPage();const ownerResponse=await owner.goto(settings.origin+'/app/pbx_meet/');ownerPage=await ownerPageFields(owner,ownerResponse);await snapshot(owner,'owner-meet');
    requireFact(ownerPage.http_status===200&&ownerPage.route==='meet'&&ownerPage.heading&&!ownerPage.login_form&&ownerPage.same_origin&&ownerPage.user_agent_matches,'normal authenticated meeting page');
    phase='create';const create=owner.locator('form').filter({has:owner.locator('input[name="action"][value="create"]')});
    await create.locator('input[name="subject"]').fill(settings.subject);
    await create.getByRole('button',{name:'Create Meeting',exact:true}).click();await snapshot(owner,'created-meet');meetingCreated=true;
    if(settings.restoredLedger){
      const createdIds=await owner.locator('form input[name="action"][value="host"]').locator('..').locator('input[name="id"]').evaluateAll(nodes=>nodes.map(node=>node.value));
      if(createdIds.length!==1)throw Error('The create response has no unique owned meeting UUID.');
      saveRestoredMeeting(createdIds[0]);
    }
    const invitation=await owner.locator('#invitation').inputValue();
    requireFact(invitation.startsWith(settings.origin+'/app/pbx_meet/join.php#'),'normal UI invitation retains trusted authority');
    phase='host_join';const popup=hostContext.waitForEvent('page');await owner.getByRole('button',{name:'Start Now',exact:true}).click();host=await popup;hostSignaling=signaling.watch(host,settings.origin);hostSecret=pathDiagnostics.capture(host,settings.origin);await host.waitForLoadState('domcontentloaded');await snapshot(host,'host-ready');
    const endpoint=await host.locator('#host-data').evaluate(node=>JSON.parse(node.textContent).websocket);
    requireFact(endpoint==='wss://'+new URL(settings.origin).host+'/meet-sip/','actual host account and browser policy retain HTTPS port');
    const idleHostToken=await host.locator('#host-data').evaluate(node=>JSON.parse(node.textContent).token);
    beforePath.host_http=await pathDiagnostics.statusProbe(settings.origin,fs.readFileSync(settings.pathProbe.caFile),idleHostToken);
    await host.getByRole('button',{name:'Join with Camera',exact:true}).click();
    phase='guest_join';guest=await guestContext.newPage();guestSignaling=signaling.watch(guest,settings.origin);guestSecret=pathDiagnostics.capture(guest,settings.origin);await guest.goto(invitation);await snapshot(guest,'guest-ready');
    await guest.locator('#name').fill('Fictional video guest');await guest.getByRole('button',{name:'Join with Camera',exact:true}).click();
    phase='admission';await host.getByRole('button',{name:'Admit',exact:true}).waitFor({timeout:20000});await snapshot(host,'guest-waiting');await host.getByRole('button',{name:'Admit',exact:true}).click();
    phase='decoded_media';const hostProof=await proof(host),guestProof=await proof(guest);
    requireFact(hostProof.codecs.every(value=>value==='video/VP8')&&guestProof.codecs.every(value=>value==='video/VP8'),'two real browsers decode mixed VP8 and independent two-way audio');
    const row=host.locator('#people > div').filter({hasText:'Fictional video guest'});
    phase='mute';await row.getByRole('button',{name:'Mute',exact:true}).click();
    await pollProof(host,p=>p?.connected&&p.power<0.000001,15000);
    requireFact(true,'host mute removes decoded guest audio');
    phase='unmute';await row.getByRole('button',{name:'Allow Microphone',exact:true}).click();await proof(host);
    requireFact(true,'host unmute restores independently decoded guest tone');
    phase='end';host.once('dialog',dialog=>dialog.accept());await host.getByRole('button',{name:'End Meeting for Everyone',exact:true}).click();
    await host.waitForFunction(()=>window.conferenceQA.pcs.every(pc=>pc.connectionState==='closed'),null,{timeout:15000});
    await guest.waitForFunction(()=>window.conferenceQA.pcs.every(pc=>pc.connectionState==='closed'),null,{timeout:15000});
    requireFact(true,'host end closes both actual browser media connections');
    afterPath=await pathDiagnostics.observe(settings,'after',{host:hostSecret(),guest:guestSecret()});
    requireFact(pathDiagnostics.roundTrips(afterPath),'backend and IIS frontend retain correlated small and delayed-fragmented SIP responses after media');
    fs.writeFileSync(settings.report,JSON.stringify({schema:1,state:'passed',checks,host:hostProof,guest:guestProof,meeting_path:{before:beforePath,after:afterPath},physical_camera:'unqualified',scope:'fictional Windows hosted runner'},null,2));
  }catch(error){failure=error;const browser_failure=await proofFailure(error);const media=['decoded_media','mute','unmute','end'].includes(phase)?{meeting_media:{host:await mediaFields(host),guest:await mediaFields(guest)}}:{};const signals=['host_join','guest_join','admission','decoded_media','mute','unmute','end'].includes(phase)?{meeting_signaling:{host:await signaling.collect(host,hostSignaling),guest:await signaling.collect(guest,guestSignaling)}}:{};const meeting_path={before:beforePath,after:afterPath||await pathDiagnostics.observe(settings,'after',{host:hostSecret(),guest:guestSecret()})};fs.writeFileSync(settings.report,JSON.stringify({schema:1,state:'failed',phase,browser_failure,...(ownerPage?{owner_page:ownerPage}:{}),...media,...signals,meeting_path}));fs.writeFileSync(path.join(evidence,'meeting-browser.private.error'),String(error.stack||error));}
  finally{
    if(meetingCreated&&owner){try{await owner.goto(settings.origin+'/app/pbx_meet/');const card=settings.restoredLedger?owner.locator('article.meet-card').filter({has:owner.locator('input[name="id"][value="'+restoredMeetingId+'"]')}):owner.locator('article.meet-card').filter({hasText:settings.subject});if(settings.restoredLedger&&(!restoredMeetingId||await card.count()!==1||await card.locator('h3').innerText()!==settings.subject))throw Error('Exact restored meeting ownership is unavailable.');if(await card.getByText('Cancel Meeting',{exact:true}).count()){await card.locator('summary').click();await card.locator('[name="confirm_cancel"]').check();await card.getByRole('button',{name:'End Meeting',exact:true}).click();}}catch(error){if(!failure)failure=error;}}
    await Promise.allSettled([hostBrowser?.close(),guestBrowser?.close()]);
  }
  if(failure){console.error('Actual Windows browser meeting media qualification failed; private evidence retained.');process.exitCode=1;}
})().catch(()=>{console.error('The bounded Windows meeting fixture could not start.');process.exitCode=1;});
