// Original Node -> native PS5 command/options; only closed component metadata escapes.
const fs=require('node:fs'),path=require('node:path'),{execFile}=require('node:child_process');
const closed=require('./windows-meet-wss-failure.cjs');
if(process.platform!=='win32'||process.env.OPENWEB_STOCK_COMPONENT!=='1'||process.env.GITHUB_ACTIONS!=='true'||process.env.RUNNER_ENVIRONMENT!=='github-hosted'||process.env.GITHUB_REPOSITORY!=='embire2/openwebpbx'||process.env.GITHUB_EVENT_NAME!=='workflow_dispatch')throw Error('Owned Windows component required.');
function nativePowerShellEnvironment(executable){
 const environment=Object.fromEntries(Object.entries(process.env).filter(([name])=>name.toUpperCase()!=='PSMODULEPATH'));
 environment.PSModulePath=path.join(path.dirname(executable),'Modules');return environment;
}
function refusal(stdout){
 try{if(typeof stdout!=='string'||Buffer.byteLength(stdout,'utf8')>2048)return null;const raw=stdout.replace(/^\uFEFF/,'').trim(),v=JSON.parse(raw);if(JSON.stringify(v)!==raw||!v||Object.keys(v).length!==9||!['schema','state','producer','stage','error_type','hresult','source_basename','source_line','caller_line'].every(k=>Object.hasOwn(v,k)))return null;
 if(v.schema!==1||v.state!=='failed'||v.producer!=='windows-stock-component.ps1'||!['component_admission','report_guard','read_report','source_pin','helper_load','original_admission','bootstrap','continuation','serialize','unknown'].includes(v.stage)||!['RuntimeException','CommandNotFoundException','FileNotFoundException','IOException','UnauthorizedAccessException','PSInvalidOperationException','InvalidOperationException','CmdletInvocationException','TypeLoadException','SessionStateUnauthorizedAccessException','other'].includes(v.error_type)||!Number.isInteger(v.hresult)||v.hresult< -2147483648||v.hresult>2147483647||!['windows-stock-component.ps1','unavailable'].includes(v.source_basename)||!['source_line','caller_line'].every(k=>Number.isInteger(v[k])&&v[k]>=0&&v[k]<1000000)||(v.source_basename==='unavailable'?v.source_line!==0:v.source_line<1))return null;return v;
 }catch{return null;}
}
const report=path.resolve(process.argv[2]),base=path.resolve(process.env.RUNNER_TEMP,'openwebpbx-stock-component');
if(!report.toLowerCase().startsWith(base.toLowerCase()+path.sep)||!/^[a-f0-9]{24}[\\/](direct|owned)\.safe\.clixml$/.test(path.relative(base,report))||fs.existsSync(report))throw Error('New owned component report required.');
const executable=path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/powershell.exe'),script=path.join(__dirname,'windows-stock-component.ps1'),started=performance.now();
execFile(executable,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',script,'-Hostname','windowsqa.example.invalid','-Port','8443','-ReportPath',report,'-DisposableHostedRunner'],{timeout:27000,maxBuffer:16384,windowsHide:true,env:nativePowerShellEnvironment(executable)},(error,stdout)=>{
 const outcome=closed.outcome(error,stdout,performance.now()-started);
 process.stdout.write(JSON.stringify({schema:1,producer:'windows-stock-component.cjs',child_outcome:outcome,native_refusal:refusal(stdout)}));if(error)process.exitCode=1;
});
