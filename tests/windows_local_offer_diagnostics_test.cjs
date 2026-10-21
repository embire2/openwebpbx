'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {syntheticSource,validCase}=require('./windows_local_offer_diagnostics.cjs');
const source=fs.readFileSync(path.join(__dirname,'windows-meet-browser.cjs'),'utf8');
assert.ok(syntheticSource(source).startsWith('function syntheticMedia('));
assert.throws(()=>syntheticSource(source.replace('frequency};','frequency,changed:true};')));
assert.throws(()=>syntheticSource(''));assert.throws(()=>syntheticSource('async function proof(page) {function syntheticMedia(frequency) {'));
const good={custom_python_user_agent:false,state:'passed',elapsed_ms:300,content_type_sdp:true,audio_mline:true,video_mline:true,vp8_offer:true,local_description:true,signaling_state:'have-local-offer',ice_gathering_state:'complete',local_live_tracks:2,phase:'complete'};
assert.ok(validCase(good));
let checks=5;
for(const [key,value]of Object.entries(good)){assert.equal(validCase({...good,[key]:null}),false);const missing={...good};delete missing[key];assert.equal(validCase(missing),false);checks+=2;}
for(const value of [null,[],[good],{...good,private_uri:'refused'},{...good,elapsed_ms:Infinity},{...good,elapsed_ms:20001},{...good,local_live_tracks:3},{...good,ice_gathering_state:'private error'}]){assert.equal(validCase(value),false);checks++;}
assert.ok(validCase({...good,state:'failed',phase:'deadline',elapsed_ms:12000,local_description:false,signaling_state:'stable',ice_gathering_state:'new'}));checks++;
console.log(checks+' bounded local-offer source/type/privacy controls passed');
