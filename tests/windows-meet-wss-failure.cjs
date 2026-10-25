// Failure-only closed transport metadata. No messages, commands or streams escape.
const psTypes=['RuntimeException','PSInvalidOperationException','InvalidOperationException','CmdletInvocationException','CommandNotFoundException','FileNotFoundException','IOException','UnauthorizedAccessException','TypeLoadException','CryptographicException','WebSocketException','AuthenticationException','TimeoutException','ManagementException','Exception','external_error'];
const codes=['none','exit','ENOENT','EACCES','EPERM','ETIMEDOUT','ABORT_ERR','ERR_CHILD_PROCESS_STDIO_MAXBUFFER','other'];
const types=['none','Error','TypeError','RangeError','TimeoutError','AbortError','other'];
const exact=(v,keys)=>!!v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).length===keys.length&&keys.every(k=>Object.hasOwn(v,k));
const integer=(v,min,max)=>Number.isInteger(v)&&v>=min&&v<=max;
function powershell(v){
 if(!exact(v,['schema','state','producer','error_type','source_basename','source_line','hresult'])||v.schema!==1||v.state!=='failed'||v.producer!=='windows-meet-wss-path.ps1'||!psTypes.includes(v.error_type)||!['windows-meet-wss-path.ps1','unavailable'].includes(v.source_basename)||!integer(v.source_line,0,999999)||!integer(v.hresult,-2147483648,2147483647)||(v.source_basename==='unavailable'?v.source_line!==0:v.source_line<1))return null;
 return {...v};
}
function validateOutcome(v){
 if(!exact(v,['exit_code','error_type','code_kind','errno','killed','signal','elapsed_ms','powershell_state','powershell'])||(v.exit_code!==null&&!integer(v.exit_code,-2147483648,4294967295))||!types.includes(v.error_type)||!codes.includes(v.code_kind)||(v.errno!==null&&!integer(v.errno,-2147483648,2147483647))||(v.killed!==null&&typeof v.killed!=='boolean')||!['none','SIGTERM','SIGKILL','other'].includes(v.signal)||!integer(v.elapsed_ms,0,32000)||!['absent','invalid','closed'].includes(v.powershell_state))return null;
 const ps=v.powershell_state==='closed'?powershell(v.powershell):null;
 if(v.powershell_state==='closed'?!ps:v.powershell!==null)return null;
 return {...v,powershell:ps};
}
function outcome(error,stdout,elapsed){
 let ps=null,state='absent';
 if(typeof stdout==='string'&&stdout.length){state='invalid';if(Buffer.byteLength(stdout,'utf8')<=16384)try{const raw=stdout.replace(/^\uFEFF/,'').trim(),value=JSON.parse(raw);if(JSON.stringify(value)===raw)ps=powershell(value);if(ps)state='closed';}catch{}}
 const code=error?.code,errno=error?.errno,name=error?.name;
 const record={exit_code:error?(integer(code,-2147483648,4294967295)?code:null):0,error_type:error?(types.includes(name)&&name!=='none'?name:'other'):'none',code_kind:error?(integer(code,-2147483648,4294967295)?'exit':codes.includes(code)&&!['none','exit'].includes(code)?code:'other'):'none',errno:integer(errno,-2147483648,2147483647)?errno:null,killed:error?(typeof error.killed==='boolean'?error.killed:null):false,signal:error?(error.signal==null?'none':['SIGTERM','SIGKILL'].includes(error.signal)?error.signal:'other'):'none',elapsed_ms:Number.isFinite(elapsed)?Math.min(32000,Math.max(0,Math.round(elapsed))):0,powershell_state:state,powershell:ps};
 return validateOutcome(record);
}
function record(label,reason,value){return validate({schema:1,label,reason,outcome:value});}
function validate(v){
 if(!exact(v,['schema','label','reason','outcome'])||v.schema!==1||!['before','after'].includes(v.label)||!['report_missing','report_invalid'].includes(v.reason))return null;
 const child=validateOutcome(v.outcome);return child?{schema:1,label:v.label,reason:v.reason,outcome:child}:null;
}
function list(v){
 if(!Array.isArray(v)||v.length<1||v.length>2)return null;
 const out=v.map(validate);if(out.some(x=>!x)||new Set(out.map(x=>x.label)).size!==out.length)return null;
 return out;
}
module.exports={powershell,outcome,record,validate,list};
