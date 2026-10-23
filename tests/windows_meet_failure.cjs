// Inert controls for the actual proof stages and closed exception categories.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const failure=require('./windows-meet-failure.cjs');
let checks=0;
function check(value){assert.ok(value);checks++;}
const source=fs.readFileSync(path.join(__dirname,'windows-meet-browser.cjs'),'utf8');
const start=source.indexOf('function syntheticMedia(frequency) {'),end=source.indexOf('\nasync function proof(page)',start);
check(start>=0&&end>start);
function probe(fault){
 const trip=stage=>{if(fault===stage)throw new TypeError('PRIVATE_PROBE_SENTINEL');};
 const analyser={fftSize:4096,frequencyBinCount:4,getFloatFrequencyData(values){trip('spectrum');values.fill(-10);},getFloatTimeDomainData(values){values.fill(.1);},connect(){return {connect(){}};}};
 const pen={drawImage(){trip('canvas_draw');},getImageData(){trip('canvas_read');return {data:new Uint8ClampedArray(160*90*4)};}};
 const remote={srcObject:{getAudioTracks(){return [{}];}},readyState:2};
 const sandbox={navigator:{mediaDevices:{}},window:{RTCPeerConnection:class{}},document:{getElementById(){return remote;},createElement(){trip('canvas_create');return {getContext(){return pen;}};}},MediaStream:class{},AudioContext:class{},setInterval(){throw Error('No synthetic generator is started by these inert controls.');},Float32Array,Set};
 const install=vm.runInNewContext('('+source.slice(start,end)+')',sandbox);install(550);
 const qa=sandbox.window.conferenceQA;
 qa.pcs.push({connectionState:'connected',async getStats(){trip('stats');return new Map([['codec',{mimeType:'video/VP8'}],['in',{type:'inbound-rtp',kind:'video',framesDecoded:13,codecId:'codec'}],['out',{type:'outbound-rtp',kind:'video',framesEncoded:17}]]);}});
 qa.audio={sampleRate:48000,destination:{},createAnalyser(){trip('analyser_create');return analyser;},createMediaStreamSource(){trip('analyser_source');return {connect(){trip('analyser_connect');}};},createGain(){trip('analyser_output');return {gain:{value:1}};}};
 return qa;
}
(async()=>{
 for(const name of ['TypeError','ReferenceError','RangeError','SecurityError','InvalidStateError','NotSupportedError']){
  const e={name:'Error',message:'page.waitForFunction: '+name+': PRIVATE_RAW_STACK_OR_TOKEN'};
  const row=failure.fields(e,'stats');check(failure.validate(row)!==null);check(!JSON.stringify(row).includes('PRIVATE'));check(row.kind!=='other');
 }
 check(failure.fields({name:'TimeoutError',message:'PRIVATE'},'complete').kind==='timeout');
 check(failure.fields({name:'PRIVATE',message:'PRIVATE'},'PRIVATE').operation==='none');
 check(failure.fields({name:'Error',message:'PRIVATE TypeError: more'},'stats').kind==='other');
 for(const row of [null,[],{kind:'type'}, {kind:'type',operation:'stats',raw:'PRIVATE'}, {kind:'PRIVATE',operation:'stats'}, {kind:'type',operation:'PRIVATE'}, {kind:true,operation:'stats'}])check(failure.validate(row)===null);
 const inherited=Object.assign(Object.create({kind:'type',operation:'stats'}),{raw:'PRIVATE',other:'PRIVATE'});check(failure.validate(inherited)===null);
 const normal=probe();const result=await normal.proof();check(normal.proofOperation==='complete');check(result.decoded_frames===13&&result.encoded_frames===17&&result.codecs[0]==='video/VP8');
 for(const stage of ['stats','analyser_create','analyser_source','analyser_connect','analyser_output','spectrum','canvas_create','canvas_draw','canvas_read']){
  const qa=probe(stage);let caught;
  try{await qa.proof();}catch(error){caught=error;}
  check(caught?.name==='TypeError');check(qa.proofOperation===stage);
  const observed=failure.fields(caught,qa.proofOperation);qa.proofOperation='complete';
  check(observed.operation===stage&&observed.kind==='type');check(!JSON.stringify(observed).includes('PRIVATE'));
 }
 console.log(JSON.stringify({schema:1,state:'passed',checks,actual_proof_source:true,inert_browser_api_adapters:true,actual_media_qualified:false,network_or_server_changed:false}));
})().catch(error=>{console.error(error);process.exitCode=1;});
