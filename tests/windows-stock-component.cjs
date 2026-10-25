// Original Node -> native PS5 command/options; only closed component metadata escapes.
const fs=require('node:fs'),path=require('node:path'),{execFile}=require('node:child_process');
const closed=require('./windows-meet-wss-failure.cjs');
if(process.platform!=='win32'||process.env.OPENWEB_STOCK_COMPONENT!=='1'||process.env.GITHUB_ACTIONS!=='true'||process.env.RUNNER_ENVIRONMENT!=='github-hosted'||process.env.GITHUB_REPOSITORY!=='embire2/openwebpbx'||process.env.GITHUB_EVENT_NAME!=='workflow_dispatch')throw Error('Owned Windows component required.');
const report=path.resolve(process.argv[2]),base=path.resolve(process.env.RUNNER_TEMP,'openwebpbx-stock-component');
if(!report.toLowerCase().startsWith(base.toLowerCase()+path.sep)||!/^[a-f0-9]{24}[\\/](direct|owned)\.safe\.clixml$/.test(path.relative(base,report))||fs.existsSync(report))throw Error('New owned component report required.');
const executable=path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/powershell.exe'),script=path.join(__dirname,'windows-stock-component.ps1'),started=performance.now();
execFile(executable,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',script,'-Hostname','windowsqa.example.invalid','-Port','8443','-ReportPath',report,'-DisposableHostedRunner'],{timeout:27000,maxBuffer:16384,windowsHide:true},(error,stdout)=>{
 const outcome=closed.outcome(error,stdout,performance.now()-started);
 process.stdout.write(JSON.stringify({schema:1,producer:'windows-stock-component.cjs',child_outcome:outcome}));if(error)process.exitCode=1;
});
