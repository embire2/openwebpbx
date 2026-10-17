#!/usr/bin/env node
// Runs the actual meeting event handlers with controlled DOM/media/SIP doubles.
// No server, browser permissions, camera, network or production state is used.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
let checks=0;
const check=(value,message)=>{assert.ok(value,message);checks++;};
const source=fs.readFileSync(new URL('../app/pbx_meet/meet.js',import.meta.url),'utf8').replace(/^import[^\n]+\n/,'');
const deferred=()=>{let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return{promise,resolve,reject};};
const flush=async()=>{for(let i=0;i<8;i++)await Promise.resolve();};
function track(kind,id){return{kind,id,readyState:'live',enabled:true,stops:0,stop(){this.readyState='ended';this.stops++;}};}
class Stream{constructor(tracks=[]){this.tracks=tracks;}getTracks(){return this.tracks;}getVideoTracks(){return this.tracks.filter(t=>t.kind==='video');}getAudioTracks(){return this.tracks.filter(t=>t.kind==='audio');}}
function fixture(camera=true){
 const elements=new Map(),docEvents={},windowEvents={},acquired=[],screens=[],replacements=[];
 const element=id=>{if(!elements.has(id))elements.set(id,{textContent:id==='host-data'?'null':'',value:'',hidden:false,disabled:false,dataset:{},length:0,replaceChildren(){},add(){},append(){},play:async()=>{}});return elements.get(id);};
 const initial=camera?track('video','original-camera'):null;
 const sender={track:initial,async replaceTrack(value){this.track=value;replacements.push(value);}};
 const transceiver={sender,currentDirection:'sendrecv',direction:'sendrecv',receiver:{track:track('video','remote')}};
 const pc={getSenders:()=>[sender],getTransceivers:()=>[transceiver],getReceivers:()=>[],addEventListener(){}};
 const state={gum:null,display:null,gumCalls:0,displayCalls:0,reloads:0};
 const media={enumerateDevices:async()=>[],getUserMedia:async()=>{state.gumCalls++;if(state.gum)return state.gum.promise;const t=track('video','camera-'+state.gumCalls);acquired.push(t);return new Stream([t]);},getDisplayMedia:async()=>{state.displayCalls++;if(state.display)return state.display.promise;const t=track('video','screen-'+state.displayCalls);screens.push(t);return new Stream([t]);}};
 const context=vm.createContext({console,MediaStream:Stream,Option:class{},UserAgent:class{},Inviter:class{},SessionState:{Established:'established',Terminated:'terminated'},location:{hash:'',pathname:'/app/pbx_meet/join.php',reload(){state.reloads++;}},history:{replaceState(){context.location.hash='';}},setInterval:()=>1,clearInterval(){},confirm:()=>true,navigator:{mediaDevices:media},document:{visibilityState:'visible',getElementById:element,createElement:()=>({append(){}}),createTextNode:x=>x,addEventListener:(event,callback)=>{docEvents[event]=callback;}},window:{addEventListener:(event,callback)=>{windowEvents[event]=callback;}},fetch:async()=>({ok:true,json:async()=>({subject:'Test meeting',state:'waiting',role:'guest',started:false,locked:false,video:true,people:[]})})});
 vm.runInContext(source+`\nglobalThis.controls={setup(input){account={video:true,token:'test-token'};cameraWanted=input.wanted;cameraTrack=input.track;call=input.call;baseConstraints={audio:true,video:input.wanted};},snapshot(){return{cameraWanted,cameraTrack,sharing,ended,invitation};},clearAccount(){account=null;},stopTracks,leave};`,context);
 context.controls.setup({wanted:camera,track:initial,call:{state:'established',_videoSender:sender,sessionDescriptionHandler:{peerConnection:pc},invite:async()=>{},bye:async()=>{},cancel:async()=>{}}});
 const click=id=>element(id).onclick();
 return{context,state,initial,sender,acquired,screens,replacements,element,click,hash(value){context.location.hash='#'+value;windowEvents.hashchange();},read:()=>context.controls.snapshot(),hide:async()=>{context.document.visibilityState='hidden';docEvents.visibilitychange();await flush();},show:async()=>{context.document.visibilityState='visible';docEvents.visibilitychange();await flush();}};
}
{
 const f=fixture();await f.click('share');const screen=f.sender.track;
 check(screen.id==='screen-1','Explicit share sends the chosen screen');
 await f.hide();check(f.initial.readyState==='ended','Hiding while sharing stops the camera');check(!f.read().cameraWanted,'Hiding clears camera intent');check(f.sender.track===screen&&screen.readyState==='live','Explicit screen sharing continues without the camera');
 screen.readyState='ended';await screen.onended();check(f.sender.track===null&&!f.read().sharing,'Browser stop-sharing while hidden never restores the camera');check(f.state.gumCalls===0,'Hidden share termination acquires no camera');
 await f.show();check(f.sender.track===null&&!f.read().cameraWanted&&f.state.gumCalls===0,'Returning to the tab requires a new camera click');
}
{
 const f=fixture();await f.click('share');const screen=f.sender.track;
 await f.click('camera');check(f.initial.readyState==='ended'&&!f.read().cameraWanted,'Camera-off explicitly stops capture');check(f.sender.track===screen&&screen.readyState==='live','Camera-off does not replace the shared screen');
 await f.click('share');check(screen.readyState==='ended','Explicit Stop Sharing stops the display track');check(!f.read().sharing&&f.sender.track===null,'Stop Sharing cleans state without relying on an ended event');check(f.element('share').textContent==='Share Screen','Stop Sharing resets its button');
}
{
 const f=fixture(false);await f.click('share');const screen=f.sender.track;
 await f.click('camera');const camera=f.acquired[0];check(f.read().cameraWanted&&camera.readyState==='live','Explicit camera-on records user intent while sharing');check(f.sender.track===screen,'Camera-on does not silently replace screen transmission');
 await f.click('share');check(f.sender.track===camera&&screen.readyState==='ended','Visible Stop Sharing restores only the explicitly enabled camera');
}
{
 const f=fixture(false),pending=deferred();f.state.gum=pending;const enabling=f.click('camera');await flush();await f.hide();const late=track('video','late-camera');pending.resolve(new Stream([late]));await enabling;
 check(late.readyState==='ended','Camera returned after tab hide is stopped immediately');check(f.sender.track===null&&!f.read().cameraWanted,'Late camera result cannot transmit or restore intent');
}
{
 const f=fixture(false),pending=deferred();f.state.gum=pending;const enabling=f.click('camera');await flush();await f.context.controls.leave(false);const late=track('video','left-camera');pending.resolve(new Stream([late]));await enabling;
 check(late.readyState==='ended'&&f.read().ended,'Camera returned after leaving is stopped');check(!f.replacements.includes(late),'Leaving prevents a late camera attachment');
}
{
 const f=fixture(),pending=deferred();f.state.display=pending;const sharing=f.click('share');await flush();await f.context.controls.leave(false);const late=track('video','left-screen');pending.resolve(new Stream([late]));await sharing;
 check(late.readyState==='ended'&&!f.read().sharing,'Screen returned after leaving is stopped');check(!f.replacements.includes(late),'Leaving prevents a late screen attachment');
}
{
 const f=fixture(false),pending=deferred();f.state.gum=pending;const enabling=f.click('camera');await flush();pending.reject(new Error('Permission denied'));await enabling;
 check(!f.read().cameraWanted&&f.sender.track===null,'Declined camera permission keeps camera off');check(f.element('camera').textContent==='Turn Camera On','Permission failure leaves a truthful camera control');
}
{
 const f=fixture();await f.click('share');const old=f.sender.track;await f.click('share');await f.click('share');const current=f.sender.track;await old.onended();
 check(f.sender.track===current&&current.readyState==='live','A stale display-ended event cannot detach a new share');
}
{
 const f=fixture(),pending=deferred();f.state.display=pending;const sharing=f.click('share');await flush();f.context.controls.stopTracks();const late=track('video','failed-screen');pending.resolve(new Stream([late]));await sharing;
 check(late.readyState==='ended'&&!f.replacements.includes(late),'Media failure invalidates a pending screen request');
}
{
 const f=fixture(),next='a'.repeat(64);f.hash(next);
 check(f.state.reloads===1,'A new valid invitation reloads an active room');check(f.context.location.hash==='#'+next,'Reload keeps the new invitation for the next document');
}
{
 const f=fixture();await f.context.controls.leave(false);f.hash('b'.repeat(64));check(f.state.reloads===1,'A new invitation also reloads after leaving the previous room');
}
{
 const f=fixture();f.context.controls.clearAccount();const next='c'.repeat(64);f.hash(next);
 check(f.state.reloads===0&&f.read().invitation===next&&f.context.location.hash==='','Before joining, a new invitation updates in place and removes its fragment');
}
{
 const f=fixture();f.hash('invalid-invite');check(f.state.reloads===0&&f.context.location.hash==='','Malformed fragments never reload or change an active account');
}
console.log(`PASS ${checks} actual meeting-handler privacy controls (controlled DOM/media/SIP; no native browser or hardware claim)`);
