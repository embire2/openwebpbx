import {UserAgent, Inviter, SessionState} from './vendor/sip.js';
const $=id=>document.getElementById(id);
let account=JSON.parse($('host-data').textContent), invitation=location.hash.slice(1), ua, call, timer, cameraWanted=false, cameraRevision=0, shareRevision=0, sharingPending=false, connecting=false, ended=false, sharing, cameraTrack, microphoneTrack, baseConstraints;
// Invitation secrets never enter an HTTP URL, access log, referrer or browser history.
history.replaceState(null,'',location.pathname);
window.addEventListener('hashchange',()=>{
 const next=location.hash.slice(1);
 // A new invitation must not reuse an admitted or ended room's credentials.
 // Reload preserves the new fragment; pagehide closes the previous call.
 if(account&&/^[a-f0-9]{64}$/.test(next)){location.reload();return;}
 if(!account)invitation=next;history.replaceState(null,'',location.pathname);
});
if(account){$('name').value='Host';invitation='';}
const say=text=>{$('status').textContent=text;};
async function api(action,extra={}) {
 const response=await fetch('./api.php',{method:'POST',headers:{'Content-Type':'application/json',...(account?{'Authorization':'Bearer '+account.token}:{})},body:JSON.stringify({action,...extra}),cache:'no-store'});
 const data=await response.json();if(!response.ok)throw new Error(data.error||'The meeting service could not be reached.');return data;
}
function cameraLabel(){$('camera').textContent=cameraWanted?'Turn Camera Off':account?.video?'Turn Camera On':'Camera Off (audio meeting)';}
function preview(){const track=sharing?.getVideoTracks()[0]||(cameraWanted&&document.visibilityState==='visible'&&cameraTrack?.readyState==='live'?cameraTrack:null);$('preview').srcObject=track?new MediaStream([track]):null;}
function stopTracks(){cameraWanted=false;cameraRevision++;shareRevision++;cameraTrack?.stop();cameraTrack=null;microphoneTrack?.stop();const stream=sharing;sharing=null;stream?.getTracks().forEach(t=>t.stop());call?.sessionDescriptionHandler?.peerConnection?.getSenders().forEach(s=>s.track?.stop());$('preview').srcObject=null;cameraLabel();}
async function cameraOff(){
 cameraWanted=false;cameraRevision++;cameraTrack?.stop();cameraTrack=null;cameraLabel();
 // Turning off the camera never replaces an actively shared screen.
 if(!sharing){const sender=videoSender();sender?.track?.stop();await sender?.replaceTrack(null);}
 preview();
}
async function finishSharing(stream){
 if(!stream||sharing!==stream)return;sharing=null;shareRevision++;
 // MediaStreamTrack.stop() does not fire ended: explicit and browser-UI stops
 // both use this idempotent cleanup rather than depending on that event.
 stream.getTracks().forEach(t=>t.stop());
 const restore=!ended&&document.visibilityState==='visible'&&cameraWanted&&cameraTrack?.readyState==='live';
 if(!restore){cameraWanted=false;cameraRevision++;cameraTrack?.stop();cameraTrack=null;}
 cameraLabel();$('share').textContent='Share Screen';
 await videoSender()?.replaceTrack(restore?cameraTrack:null);preview();
}
async function leave(notify=true){
 if(ended)return;ended=true;clearInterval(timer);stopTracks();
 try{if(call?.state===SessionState.Established)await call.bye();else if(call)await call.cancel();}catch{}
 try{await ua?.stop();}catch{}if(notify&&account)try{await api('leave');}catch{}
 $('stage').hidden=true;$('welcome').hidden=true;$('host-controls').hidden=true;say('You have left the meeting. You can close this tab.');
}
async function devices(){
 const rows=await navigator.mediaDevices.enumerateDevices();
 for(const [id,kind]of[['microphones','audioinput'],['cameras','videoinput']]){
  const select=$(id),saved=select.value;select.replaceChildren(new Option(kind==='audioinput'?'System microphone':'System camera',''));
  for(const row of rows.filter(r=>r.kind===kind))select.add(new Option(row.label||`${kind==='audioinput'?'Microphone':'Camera'} ${select.length}`,row.deviceId));select.value=saved;
 }
}
function videoSender(){return call?.sessionDescriptionHandler?.peerConnection?.getSenders().find(s=>s.track?.kind==='video'||s===call._videoSender);}
async function connect(){
 if(connecting||call||ended||document.visibilityState!=='visible')return;connecting=true;say('Connecting to your meeting…');
 try{
  ua=new UserAgent({uri:UserAgent.makeURI(`sip:${account.username}@${account.domain}`),authorizationUsername:account.username,authorizationPassword:account.password,
   transportOptions:{server:account.websocket},logBuiltinEnabled:false,logConfiguration:false,userAgentString:'OpenWebPBX Meet',
   delegate:{onInvite:invitation=>invitation.reject()},sessionDescriptionHandlerFactoryOptions:{iceGatheringTimeout:3000,peerConnectionConfiguration:{iceServers:[]}}});
  await ua.start();
  const constraints={audio:{echoCancellation:true,noiseSuppression:true,...($('microphones').value?{deviceId:{exact:$('microphones').value}}:{})},video:cameraWanted&&document.visibilityState==='visible'&&account.video?{width:{ideal:640},height:{ideal:360},frameRate:{ideal:15},...($('cameras').value?{deviceId:{exact:$('cameras').value}}:{})}:false};
  baseConstraints=constraints;
  call=new Inviter(ua,UserAgent.makeURI(`sip:${account.number}@${account.domain}`),{sessionDescriptionHandlerOptions:{constraints,offerOptions:{offerToReceiveVideo:account.video}}});
  call.stateChange.addListener(async state=>{
   if(state===SessionState.Established){
    const pc=call.sessionDescriptionHandler.peerConnection;call._videoSender=pc.getTransceivers().find(t=>t.receiver.track.kind==='video')?.sender;
    microphoneTrack=pc.getSenders().find(s=>s.track?.kind==='audio')?.track;cameraTrack=call._videoSender?.track;
    if(!cameraWanted||document.visibilityState!=='visible')await cameraOff();
    const remote=new MediaStream();pc.getReceivers().forEach(r=>{if(r.track)remote.addTrack(r.track);});$('remote').srcObject=remote;
    pc.addEventListener('track',e=>{if(!remote.getTrackById(e.track.id))remote.addTrack(e.track);});
    pc.addEventListener('connectionstatechange',()=>{if(pc.connectionState==='failed'){$('media-help').textContent='Your media connection was lost. Leave and rejoin, or try another network.';stopTracks();}});
    preview();cameraLabel();$('camera').disabled=!account.video;
    $('welcome').hidden=true;$('stage').hidden=false;$('people-panel').hidden=false;$('leave-waiting').hidden=true;
    $('share').hidden=!account.video||!navigator.mediaDevices.getDisplayMedia;
    try{await $('remote').play();}catch{$('media-help').textContent='Tap the meeting video to hear your meeting.';}
    say('Connected. Your microphone and camera are controlled by the buttons below.');devices().catch(()=>{});
   }else if(state===SessionState.Terminated&&!ended){await leave(false);say('Your meeting call ended. Reopen your invitation to join again.');}
  });
  await call.invite({requestDelegate:{onReject:()=>{say('Could not join the meeting. Ask the host to check that it is open.');stopTracks();}}});
 }catch(error){stopTracks();try{await ua?.stop();}catch{}call=null;connecting=false;say(error.name==='NotAllowedError'?'Microphone or camera permission was declined. Allow it in your browser, then try again.':error.name==='NotFoundError'?'That microphone or camera is unavailable. Choose audio or another device.':'Could not connect to the meeting. Check your network and try again.');$('welcome').hidden=false;}
}
async function refresh(){
 if(!account||ended)return;
 try{
  const state=await api('status');$('subject').textContent=state.subject;$('host-controls').hidden=state.role!=='host';$('people-panel').hidden=false;$('lock').textContent=state.locked?'Unlock Meeting':'Lock Meeting';$('lock').dataset.locked=state.locked?'1':'';
  if(state.state==='waiting')say('You are in the waiting room. The host will admit you.');
  else if(!state.started)say('Waiting for the host to start the meeting.');
  else await connect();
  $('people').replaceChildren();
  for(const person of state.people){
   const row=document.createElement('div'),label=document.createElement('strong');label.textContent=person.member_name;row.append(label,document.createTextNode(` · ${person.role==='host'?'Host':person.state==='waiting'?'Waiting':person.connected?'Connected':'Joining'}${person.muted?' · Muted by host':''}`));
   if(state.role==='host'&&person.role!=='host'){
    for(const [action,title]of person.state==='waiting'?[['admit','Admit'],['remove','Decline']]:[[person.muted?'unmute':'mute',person.muted?'Allow Microphone':'Mute'],['remove','Remove']]){
     const button=document.createElement('button');button.textContent=title;button.onclick=async()=>{button.disabled=true;try{await api(action,{member:person.member_uuid});await refresh();}catch(e){say(e.message);button.disabled=false;}};row.append(button);
    }
   }$('people').append(row);
  }
 }catch(error){if(error.message.includes('ended')||error.message.includes('left')||error.message.includes('unavailable')){await leave(false);say(error.message);}else say('Connection to the meeting service was interrupted. Retrying…');}
}
async function join(video){
 $('join-audio').disabled=true;$('join-video').disabled=true;
 try{
  if(!navigator.mediaDevices?.getUserMedia)throw new Error('Use a supported browser over HTTPS to join.');
  cameraWanted=video;cameraRevision++;
  if(!account)account=await api('join',{invite:invitation,name:$('name').value});
  if(!account.video&&video){cameraWanted=false;say('This is an audio conference. Joining without a camera.');}
  $('join-video').hidden=!account.video;$('welcome').hidden=true;await refresh();timer=setInterval(refresh,2500);
 }catch(error){say(error.message);$('welcome').hidden=false;}
 finally{$('join-audio').disabled=false;$('join-video').disabled=false;}
}
$('join-audio').onclick=()=>join(false);$('join-video').onclick=()=>join(true);
$('remote').onclick=()=>$('remote').play().catch(()=>{});
$('leave').onclick=()=>leave();$('leave-waiting').onclick=()=>leave();
$('microphone').onclick=()=>{if(microphoneTrack){microphoneTrack.enabled=!microphoneTrack.enabled;$('microphone').textContent=microphoneTrack.enabled?'Mute Microphone':'Unmute Microphone';}};
$('camera').onclick=async()=>{
 let revision;
 try{
  const sender=videoSender();if(!sender||ended||!account.video)return;
  if(cameraWanted){await cameraOff();return;}
  if(document.visibilityState!=='visible')return;
  cameraWanted=true;revision=++cameraRevision;cameraLabel();
  const stream=await navigator.mediaDevices.getUserMedia({video:{width:{ideal:640},height:{ideal:360},frameRate:{ideal:15},...($('cameras').value?{deviceId:{exact:$('cameras').value}}:{})}});
  if(ended||revision!==cameraRevision||!cameraWanted||document.visibilityState!=='visible'){stream.getTracks().forEach(t=>t.stop());return;}
  cameraTrack=stream.getVideoTracks()[0];if(!cameraTrack)throw new Error('No camera track');
  if(!sharing){await sender.replaceTrack(cameraTrack);const transceiver=call.sessionDescriptionHandler.peerConnection.getTransceivers().find(t=>t.sender===sender);if(cameraWanted&&document.visibilityState==='visible'&&transceiver?.currentDirection==='recvonly'){transceiver.direction='sendrecv';await call.invite({sessionDescriptionHandlerOptions:{constraints:baseConstraints}});}}
  preview();cameraLabel();
 }catch{if(revision===undefined||revision===cameraRevision){await cameraOff().catch(()=>{});if(!ended)say('Could not change your camera. Check your browser camera permission.');}}
};
$('share').onclick=async()=>{
 let stream,revision;
 try{
  if(sharing){await finishSharing(sharing);return;}
  const sender=videoSender();if(!sender||ended||!account.video||sharingPending)return;
  sharingPending=true;revision=++shareRevision;$('share').disabled=true;
  stream=await navigator.mediaDevices.getDisplayMedia({video:true,audio:false});
  if(ended||revision!==shareRevision){stream.getTracks().forEach(t=>t.stop());return;}
  const track=stream.getVideoTracks()[0];if(!track)throw new Error('No screen track');
  sharing=stream;track.onended=()=>finishSharing(stream).catch(()=>{if(!ended)say('Screen sharing stopped.');});
  await sender.replaceTrack(track);const transceiver=call.sessionDescriptionHandler.peerConnection.getTransceivers().find(t=>t.sender===sender);if(transceiver?.currentDirection==='recvonly'){transceiver.direction='sendrecv';await call.invite({sessionDescriptionHandlerOptions:{constraints:baseConstraints}});}
  if(sharing===stream){preview();$('share').textContent='Stop Sharing';}
 }catch{if(stream){if(sharing===stream)await finishSharing(stream).catch(()=>{});else stream.getTracks().forEach(t=>t.stop());}if(!ended)say('Screen sharing was canceled or is unavailable.');}
 finally{if(revision!==undefined){sharingPending=false;$('share').disabled=false;}}
};
$('lock').onclick=async()=>{try{await api($('lock').dataset.locked?'unlock':'lock');await refresh();}catch(e){say(e.message);}};
$('end').onclick=async()=>{if(confirm('End this meeting for everyone?'))try{await api('end');await leave(false);say('The meeting has ended for everyone.');}catch(e){say(e.message);}};
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='hidden'){cameraOff().catch(()=>{});}else if(document.visibilityState==='visible')refresh();});
window.addEventListener('pagehide',()=>{stopTracks();ua?.stop().catch(()=>{});if(account)fetch('./api.php',{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer '+account.token},body:JSON.stringify({action:'leave'}),keepalive:true}).catch(()=>{});});
devices().catch(()=>{});
