// Actual pure producer and original wrapper reconstruction with explicit inert I/O.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),{createRequire}=require('node:module'),{execFile}=require('node:child_process');
const safe=require('./windows-meet-wss-failure.cjs'),realRequire=createRequire(__filename);
const SECRET='PRIVATE_URL_PASSWORD_RAW_STDERR';let checks=0;
function check(value){assert(value);checks++;}
const ps={schema:1,state:'failed',producer:'windows-meet-wss-path.ps1',error_type:'RuntimeException',source_basename:'windows-meet-wss-path.ps1',source_line:73,hresult:-2146233087};
function clone(v){return JSON.parse(JSON.stringify(v));}
function done(exe,args,options){const started=performance.now();return new Promise(resolve=>execFile(exe,args,options,(error,stdout)=>resolve(safe.outcome(error,stdout,performance.now()-started))));}
function wrapper(source,mode,events,onError=false){
 const filename=path.join(__dirname,'windows-meet-path-diagnostics.cjs'),module={exports:{}};let called=false;
 const report=path.join('/owned/evidence','meeting-wss-before.safe.json');
 const reportRow={schema:1,state:'observed',...Object.fromEntries(['backend','frontend','fragmented_backend','fragmented_frontend'].map(k=>[k,{...realRequire('./windows-meet-path-diagnostics.cjs').defaults()[k],observed:true}]))};
 const raw=mode==='malformed-report'?'PRIVATE_BAD_JSON':JSON.stringify(reportRow);
 const available=()=>called&&['valid-report','malformed-report'].includes(mode);const ordinary=()=>{if(!available())throw Object.assign(Error(SECRET),{code:'ENOENT'});};
 const fakeFs={...fs,existsSync:p=>p===report?available():false,lstatSync:()=>{ordinary();return {isFile:()=>true};},statSync:()=>{ordinary();return {size:Buffer.byteLength(raw)};},readFileSync:p=>{if(p!==report)return Buffer.from('owned test public CA marker');ordinary();return raw;}};
 const fakeExec=(exe,args,options,callback)=>{
  if(exe==='owned-php'){assert.deepEqual(JSON.parse(JSON.stringify(args)),['owned-fixture','meeting-path-state','owned-input']);assert.deepEqual(JSON.parse(JSON.stringify(options)),{timeout:6000,maxBuffer:16384,windowsHide:true});callback(null,JSON.stringify(realRequire('./windows-meet-path-diagnostics.cjs').defaults().database));return;}
  assert.equal(exe,'owned-powershell');assert.deepEqual(JSON.parse(JSON.stringify(args)),['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','owned-wss','-Hostname','windowsqa.example.invalid','-Port','8443','-ReportPath',report,'-DisposableHostedRunner']);assert.deepEqual(JSON.parse(JSON.stringify(options)),{timeout:27000,maxBuffer:16384,windowsHide:true});events.calls++;
  called=true;const error=Object.assign(Error(SECRET),{code:1,killed:false,signal:null});callback(mode==='normal-no-json'?null:error,mode==='valid-report'?'OBSERVED actual diagnostic evidence':mode==='no-output'?'':mode==='invalid-json'?SECRET:JSON.stringify(ps));
 };
 const helper=onError?{...safe,outcome:()=>{throw Error(SECRET)}}:safe;
 const custom=id=>id==='node:fs'?fakeFs:id==='node:child_process'?{execFile:fakeExec}:id==='./windows-meet-wss-failure.cjs'?helper:realRequire(id);
 vm.runInNewContext('(function(require,module,exports){'+source+'\n})',{Buffer,URL,performance,Promise,console,setTimeout,clearTimeout})(custom,module,module.exports);
 const settings={origin:'https://windowsqa.example.invalid:8443',report:'/owned/evidence/browser.json',pathProbe:{caFile:'owned-ca',powershell:'owned-powershell',wssScript:'owned-wss',php:'owned-php',fixtureScript:'owned-fixture',fixtureInput:'owned-input'}};
 return module.exports.observe(settings,'before',{},v=>{events.failures.push(v);if(mode==='observer-throws')throw Error(SECRET);});
}
async function run(original){
 check(!!safe.powershell(ps));check(!safe.powershell({...ps,private:SECRET}));
 for(const key of Object.keys(ps)){const v=clone(ps);delete v[key];check(!safe.powershell(v));}
 for(const [key,value] of [['schema',true],['source_line',0],['source_line',1000000],['source_line','73'],['hresult',2147483648],['hresult',true],['source_basename',SECRET],['error_type',SECRET]])check(!safe.powershell({...ps,[key]:value}));
 const out=await done(process.execPath,['-e',`process.stdout.write(${JSON.stringify(JSON.stringify(ps))});process.exitCode=7`],{timeout:3000,maxBuffer:16384,windowsHide:true});
 check(out.exit_code===7&&out.code_kind==='exit'&&out.powershell_state==='closed'&&out.powershell.source_line===73);
 const base=safe.record('before','report_missing',out);check(!!safe.list([base]));check(!safe.list([base,base]));check(!safe.list([]));check(!safe.list([base,base,base]));
 for(const key of Object.keys(base)){const v=clone(base);delete v[key];check(!safe.list([v]));}
 for(const key of Object.keys(out)){const v=clone(base);delete v.outcome[key];check(!safe.list([v]));}
 for(const [key,value] of [['exit_code',true],['exit_code',4294967296],['errno',-2147483649],['killed',1],['signal',SECRET],['elapsed_ms',32001],['error_type',SECRET],['code_kind',SECRET],['powershell_state',SECRET],['powershell',null]]){const v=clone(base);v.outcome[key]=value;check(!safe.list([v]));}
 const absent=await done('/nonexistent/openwebpbx-owned-command',[],{timeout:1000,maxBuffer:16384});check(absent.code_kind==='ENOENT'&&absent.powershell_state==='absent');
 const timeout=await done(process.execPath,['-e','setTimeout(()=>{},3000)'],{timeout:40,maxBuffer:16384});check(timeout.killed===true&&timeout.signal==='SIGTERM'&&timeout.exit_code===null);
 const buffer=await done(process.execPath,['-e',"process.stdout.write('x'.repeat(32768))"],{timeout:3000,maxBuffer:16384});check(buffer.code_kind==='ERR_CHILD_PROCESS_STDIO_MAXBUFFER'&&buffer.powershell_state==='invalid');
 for(const raw of ['{',SECRET,JSON.stringify({...ps,private:SECRET}),JSON.stringify(ps).replace('\"schema\":1','\"schema\":1,\"schema\":1'),'x'.repeat(16385)])check(safe.outcome(Error(SECRET),raw,1).powershell_state==='invalid');
 check(safe.outcome(null,'OBSERVED actual WSS diagnostic evidence',3).powershell_state==='invalid');
 check(!JSON.stringify([base,absent,timeout,buffer]).includes(SECRET));
 const source=fs.readFileSync(path.join(__dirname,'windows-meet-path-diagnostics.cjs'),'utf8');
 for(const mode of ['no-output','invalid-json','normal-no-json','valid-report','malformed-report','observer-throws']){
  const old={calls:0,failures:[]},current={calls:0,failures:[]};const before=await wrapper(original,mode,old),after=await wrapper(source,mode,current);
  assert.equal(JSON.stringify(after),JSON.stringify(before),mode+JSON.stringify(current));checks++;check(old.calls===1&&current.calls===1&&old.failures.length===0);check(current.failures.length===(mode==='valid-report'?0:1));
  if(current.failures.length){check(!!safe.list(current.failures));check(!JSON.stringify(current.failures).includes(SECRET));}
 }
 const observerFault={calls:0,failures:[]};const result=await wrapper(source,'no-output',observerFault,true);check(observerFault.calls===1&&observerFault.failures.length===0&&result.backend.observed===false);
 return {schema:1,state:'passed',checks,actual_execfile_exit_missing_timeout_buffer:true,original_wrapper_row_calls_deadlines_equal:true,raw_output_retained:false};
}
if(require.main===module){let input='';process.stdin.on('data',v=>input+=v);process.stdin.on('end',()=>run(JSON.parse(input).original).then(v=>console.log(JSON.stringify(v))).catch(error=>{console.error(error.stack);process.exitCode=1;}));}
module.exports={run};
