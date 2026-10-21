// Closed, QA-only browser signaling observations. Never retain SIP headers/SDP/URLs.
const booleans=['observed','endpoint_match','counts_capped','local_description','remote_description','admit_ok'];
const counts=['ws_observed','ws_closed','ws_errors','sent_register','sent_invite','admit_requests','admit_responses','status_requests','status_responses','http_failures','api_json_failures'];
const http=['admit_http_status','status_http_status'];
const enums={signaling_state:['stable','have-local-offer','have-remote-offer','have-local-pranswer','have-remote-pranswer','closed','unavailable'],ice_gathering_state:['new','gathering','complete','unavailable'],member_state:['waiting','admitted','left','removed','unavailable','other']};
const codes=['register_codes','invite_codes'];
function defaults(observed=false){return {...Object.fromEntries(booleans.map(name=>[name,name==='observed'?observed:name==='endpoint_match'])),...Object.fromEntries([...counts,...http].map(name=>[name,0])),...Object.fromEntries(Object.keys(enums).map(name=>[name,'unavailable'])),register_codes:[],invite_codes:[]};}
function validate(row){
 const fields=[...booleans,...counts,...http,...Object.keys(enums),...codes];
 if(!row||typeof row!=='object'||Array.isArray(row)||Object.keys(row).length!==fields.length||fields.some(name=>!Object.hasOwn(row,name)))return null;
 if(booleans.some(name=>typeof row[name]!=='boolean')||counts.some(name=>!Number.isInteger(row[name])||row[name]<0||row[name]>512)||http.some(name=>!Number.isInteger(row[name])||row[name]<0||row[name]>599)||Object.entries(enums).some(([name,values])=>!values.includes(row[name]))||codes.some(name=>!Array.isArray(row[name])||row[name].length>16||row[name].some(value=>!Number.isInteger(value)||value<100||value>699)))return null;
 return Object.fromEntries(fields.map(name=>[name,Array.isArray(row[name])?[...row[name]]:row[name]]));
}
function increment(row,key){if(row[key]<512)row[key]++;else row.counts_capped=true;}
function parseFrame(row,payload,sent){
 // Header names/methods/status numbers alone leave this scope. In particular,
 // credentials, Call-ID, request URIs and SDP are never stored in the observer.
 const text=typeof payload==='string'?payload.slice(0,8192):Buffer.isBuffer(payload)?payload.subarray(0,8192).toString('utf8'):'';
 if(sent){const method=/^(REGISTER|INVITE)\s+[^\r\n]+\s+SIP\/2\.0\r?\n/.exec(text);if(method)increment(row,method[1]==='REGISTER'?'sent_register':'sent_invite');return;}
 const status=/^SIP\/2\.0\s+([1-6][0-9]{2})\b/.exec(text),cseq=/(?:^|\r?\n)CSeq:\s*[0-9]+\s+(REGISTER|INVITE)\s*(?:\r?\n|$)/i.exec(text);
 if(!status||!cseq)return;
 const key=cseq[1].toUpperCase()==='REGISTER'?'register_codes':'invite_codes';
 if(row[key].length===16){row[key].shift();row.counts_capped=true;}row[key].push(Number(status[1]));
}
function watch(page,origin){
 const row=defaults(true),requests=new WeakMap(),expectedSocket='wss://'+new URL(origin).host+'/meet-sip/';
 page.on('websocket',socket=>{
  if(socket.url()!==expectedSocket){row.endpoint_match=false;return;}
  increment(row,'ws_observed');socket.on('framesent',frame=>parseFrame(row,frame.payload,true));socket.on('framereceived',frame=>parseFrame(row,frame.payload,false));socket.on('socketerror',()=>increment(row,'ws_errors'));socket.on('close',()=>increment(row,'ws_closed'));
 });
 page.on('request',request=>{
  try{
   const url=new URL(request.url());if(url.pathname!=='/app/pbx_meet/api.php')return;
   if(url.origin!==origin){row.endpoint_match=false;return;}if(request.method()!=='POST')return;
   const action=request.postDataJSON()?.action;if(action!=='admit'&&action!=='status')return;
   requests.set(request,action);increment(row,action==='admit'?'admit_requests':'status_requests');
  }catch{ /* An unrecognized body is never exported. */ }
 });
 page.on('requestfailed',request=>{if(requests.has(request))increment(row,'http_failures');});
 page.on('response',async response=>{
  const action=requests.get(response.request());if(!action)return;
  increment(row,action==='admit'?'admit_responses':'status_responses');row[action==='admit'?'admit_http_status':'status_http_status']=response.status();
  try{const data=await response.json();if(action==='admit')row.admit_ok=data?.ok===true;else row.member_state=enums.member_state.includes(data?.state)?data.state:'other';}catch{increment(row,'api_json_failures');}
 });
 return row;
}
async function collect(page,record){
 const row=validate(record)||defaults();if(!page)return row;
 let timer;
 try{
  const pc=await Promise.race([page.evaluate(()=>{const pcs=window.conferenceQA?.pcs||[],pc=pcs.findLast(candidate=>candidate.connectionState==='connected')||pcs.at(-1);return {signaling_state:pc?.signalingState||'unavailable',ice_gathering_state:pc?.iceGatheringState||'unavailable',local_description:!!pc?.localDescription,remote_description:!!pc?.remoteDescription};}),new Promise(resolve=>{timer=setTimeout(()=>resolve(null),3000);})]);
  if(pc&&enums.signaling_state.includes(pc.signaling_state)&&enums.ice_gathering_state.includes(pc.ice_gathering_state)&&typeof pc.local_description==='boolean'&&typeof pc.remote_description==='boolean')Object.assign(row,{signaling_state:pc.signaling_state,ice_gathering_state:pc.ice_gathering_state,local_description:pc.local_description,remote_description:pc.remote_description});
 }catch{ /* A failed probe leaves explicit unavailable state, never raw errors. */ }finally{clearTimeout(timer);}
 return validate(row)||defaults();
}
module.exports={defaults,validate,watch,parseFrame,collect};
