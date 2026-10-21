// Actual product UI, IIS/WSS, DTLS/SRTP and decoded browser media on an owned runner.
const fs = require('node:fs');
const path = require('node:path');
if(process.platform !== 'win32' || process.env.OPENWEB_WINDOWS_NATIVE_TEST !== '1' || process.env.GITHUB_ACTIONS !== 'true' || process.env.RUNNER_ENVIRONMENT !== 'github-hosted' || process.env.GITHUB_REPOSITORY !== 'embire2/openwebpbx') throw Error('An explicitly disposable Windows runner is required.');
const settings = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const {chromium} = require(path.join(settings.dependencies, 'node_modules', 'playwright-core'));
if(!/^https:\/\/windowsqa\.example\.invalid(?::[0-9]+)?$/.test(settings.origin) || !Array.isArray(settings.cookies)) throw Error('The owned qualification HTTPS origin is required.');
const evidence = path.dirname(process.argv[2]);
const checks = [];
let hostBrowser, guestBrowser, owner, host, guest, meetingCreated = false;
let phase = 'browser_start';
function requireFact(value, name) {if(!value) throw Error(name); checks.push(name);}
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
    const pc = qa.pcs.findLast(candidate => candidate.connectionState === 'connected');
    if(!pc) return {connected:false,states:qa.pcs.map(candidate=>candidate.connectionState)};
    let decoded=0, encoded=0; const codecs=[]; const stats=await pc.getStats();
    for(const row of stats.values()){
      if(row.type==='inbound-rtp' && row.kind==='video'){decoded+=row.framesDecoded||0; codecs.push(stats.get(row.codecId)?.mimeType);}
      if(row.type==='outbound-rtp' && row.kind==='video')encoded+=row.framesEncoded||0;
    }
    const remote=document.getElementById('remote');
    if(!qa.analyser && remote.srcObject?.getAudioTracks().length){
      qa.analyser=qa.audio.createAnalyser();qa.analyser.fftSize=4096;qa.analyser.smoothingTimeConstant=0;
      qa.audio.createMediaStreamSource(new MediaStream(remote.srcObject.getAudioTracks())).connect(qa.analyser);
      const silent=qa.audio.createGain();silent.gain.value=0;qa.analyser.connect(silent).connect(qa.audio.destination);
    }
    let total=0, band=0, power=0;
    if(qa.analyser){
      const bins=new Float32Array(qa.analyser.frequencyBinCount), samples=new Float32Array(qa.analyser.fftSize);
      qa.analyser.getFloatFrequencyData(bins);qa.analyser.getFloatTimeDomainData(samples);
      for(let i=2;i<bins.length;i++){const energy=10**(bins[i]/10), hz=i*qa.audio.sampleRate/qa.analyser.fftSize;total+=energy;if(Math.abs(hz-(frequency===550?770:550))<35)band+=energy;}
      for(const sample of samples)power+=sample*sample;power/=samples.length;
    }
    const canvas=document.createElement('canvas');canvas.width=160;canvas.height=90;let colors=0;
    if(remote.readyState>=2){const pen=canvas.getContext('2d');pen.drawImage(remote,0,0,160,90);const pixels=pen.getImageData(0,0,160,90).data,set=new Set();for(let i=0;i<pixels.length;i+=28)set.add(pixels.slice(i,i+3).join(','));colors=set.size;}
    return {connected:true,decoded_frames:decoded,encoded_frames:encoded,codecs,video_colors:colors,tone_ratio:total?band/total:0,power};
  };
}
async function proof(page) {
  await page.waitForFunction(async()=>{const p=await window.conferenceQA?.proof();return p?.connected&&p.decoded_frames>=10&&p.video_colors>8&&p.tone_ratio>.65&&p.power>0.00001;},null,{timeout:45000});
  return page.evaluate(()=>window.conferenceQA.proof());
}
(async()=>{
  let failure;
  try{
    const launch={channel:'msedge',headless:true,args:['--autoplay-policy=no-user-gesture-required','--disable-features=WebRtcHideLocalIpsWithMdns']};
    hostBrowser=await chromium.launch(launch);guestBrowser=await chromium.launch(launch);
    const hostContext=await hostBrowser.newContext({ignoreHTTPSErrors:false});
    const guestContext=await guestBrowser.newContext({ignoreHTTPSErrors:false});
    await hostContext.addInitScript(syntheticMedia,550);await guestContext.addInitScript(syntheticMedia,770);
    await hostContext.addCookies(settings.cookies);
    phase='owner_page';owner=await hostContext.newPage();await owner.goto(settings.origin+'/app/pbx_meet/');await snapshot(owner,'owner-meet');
    requireFact(await owner.getByRole('heading',{name:'Meet',exact:true}).isVisible(),'normal authenticated meeting page');
    phase='create';const create=owner.locator('form').filter({has:owner.locator('input[name="action"][value="create"]')});
    await create.locator('input[name="subject"]').fill(settings.subject);
    await create.getByRole('button',{name:'Create Meeting',exact:true}).click();await snapshot(owner,'created-meet');meetingCreated=true;
    const invitation=await owner.locator('#invitation').inputValue();
    requireFact(invitation.startsWith(settings.origin+'/app/pbx_meet/join.php#'),'normal UI invitation retains trusted authority');
    phase='host_join';const popup=hostContext.waitForEvent('page');await owner.getByRole('button',{name:'Start Now',exact:true}).click();host=await popup;await host.waitForLoadState('domcontentloaded');await snapshot(host,'host-ready');
    const endpoint=await host.locator('#host-data').evaluate(node=>JSON.parse(node.textContent).websocket);
    requireFact(endpoint==='wss://'+new URL(settings.origin).host+'/meet-sip/','actual host account and browser policy retain HTTPS port');
    await host.getByRole('button',{name:'Join with Camera',exact:true}).click();
    phase='guest_join';guest=await guestContext.newPage();await guest.goto(invitation);await snapshot(guest,'guest-ready');
    await guest.locator('#name').fill('Fictional video guest');await guest.getByRole('button',{name:'Join with Camera',exact:true}).click();
    phase='admission';await host.getByRole('button',{name:'Admit',exact:true}).waitFor({timeout:20000});await snapshot(host,'guest-waiting');await host.getByRole('button',{name:'Admit',exact:true}).click();
    phase='decoded_media';const hostProof=await proof(host),guestProof=await proof(guest);
    requireFact(hostProof.codecs.every(value=>value==='video/VP8')&&guestProof.codecs.every(value=>value==='video/VP8'),'two real browsers decode mixed VP8 and independent two-way audio');
    const row=host.locator('#people > div').filter({hasText:'Fictional video guest'});
    phase='mute';await row.getByRole('button',{name:'Mute',exact:true}).click();
    await host.waitForFunction(async()=>{const p=await window.conferenceQA.proof();return p.connected&&p.power<0.000001;},null,{timeout:15000});
    requireFact(true,'host mute removes decoded guest audio');
    phase='unmute';await row.getByRole('button',{name:'Allow Microphone',exact:true}).click();await proof(host);
    requireFact(true,'host unmute restores independently decoded guest tone');
    phase='end';host.once('dialog',dialog=>dialog.accept());await host.getByRole('button',{name:'End Meeting for Everyone',exact:true}).click();
    await host.waitForFunction(()=>window.conferenceQA.pcs.every(pc=>pc.connectionState==='closed'),null,{timeout:15000});
    await guest.waitForFunction(()=>window.conferenceQA.pcs.every(pc=>pc.connectionState==='closed'),null,{timeout:15000});
    requireFact(true,'host end closes both actual browser media connections');
    fs.writeFileSync(settings.report,JSON.stringify({schema:1,state:'passed',checks,host:hostProof,guest:guestProof,physical_camera:'unqualified',scope:'fictional Windows hosted runner'},null,2));
  }catch(error){failure=error;fs.writeFileSync(settings.report,JSON.stringify({schema:1,state:'failed',phase}));fs.writeFileSync(path.join(evidence,'meeting-browser.private.error'),String(error.stack||error));}
  finally{
    if(meetingCreated&&owner){try{await owner.goto(settings.origin+'/app/pbx_meet/');const card=owner.locator('article.meet-card').filter({hasText:settings.subject});if(await card.getByText('Cancel Meeting',{exact:true}).count()){await card.locator('summary').click();await card.locator('[name="confirm_cancel"]').check();await card.getByRole('button',{name:'End Meeting',exact:true}).click();}}catch(error){if(!failure)failure=error;}}
    await Promise.allSettled([hostBrowser?.close(),guestBrowser?.close()]);
  }
  if(failure){console.error('Actual Windows browser meeting media qualification failed; private evidence retained.');process.exitCode=1;}
})().catch(()=>{console.error('The bounded Windows meeting fixture could not start.');process.exitCode=1;});
