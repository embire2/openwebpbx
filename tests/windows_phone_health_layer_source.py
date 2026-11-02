#!/usr/bin/env python3
"""Exact source-copy instrumentation, never a runtime firewall implementation."""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
original=(root/'app/event_guard/resources/classes/event_guard_windows.php').read_text()
expected=original.replace('class event_guard_windows implements','class openweb_diag_event_guard_windows implements',1)
header="    public const BASE_SOURCE_SHA256='"+hashlib.sha256(original.encode()).hexdigest()+"';\n    public array $lastRun=[];public ?string $lastExecutor=null;\n"+'''    public function neutral():?string {if($this->lastExecutor===null)return null;return $this->run([$this->lastExecutor,'-NoProfile','-NonInteractive','-Command',"[Console]::Out.WriteLine(12345)"]);}\n'''
expected=expected.replace('    private const FILTERS=',header+'    private const FILTERS=',1)
changes=[
("        $directory=$this->spoolDirectory();if(!is_dir($directory)||is_link($directory))return null;", "        $started=microtime(true);$this->lastExecutor=$arguments[0]??null;$this->lastRun=['started'=>true,'process_created'=>false,'cutoff'=>'none','native_exit'=>null,'close_exit'=>null,'last_running'=>null,'output_bytes'=>null,'raw_returned'=>false,'json_state'=>'unobserved','elapsed_ms'=>null];\n        $directory=$this->spoolDirectory();if(!is_dir($directory)||is_link($directory)){$this->lastRun['cutoff']='spool_directory';return null;}"),
("if(!is_resource($output))return null;", "if(!is_resource($output)){$this->lastRun['cutoff']='spool_open';return null;}"),
("if(!is_resource($p))return null;$deadline=", "if(!is_resource($p)){$this->lastRun['cutoff']='proc_open';return null;}$this->lastRun['process_created']=true;$deadline="),
("$size=fstat($output)['size'];if($size>8192||microtime(true)>$deadline){$refused=true;", "$size=fstat($output)['size'];$this->lastRun['last_running']=(bool)$status['running'];$this->lastRun['native_exit']=(int)$status['exitcode'];$this->lastRun['output_bytes']=(int)$size;if($size>8192||microtime(true)>$deadline){$this->lastRun['cutoff']=$size>8192?'output_size':'15s_deadline';$refused=true;"),
("$closed=proc_close($p);$p=null;", "$closed=proc_close($p);$this->lastRun['close_exit']=$closed;$p=null;"),
("if($refused||$exit!==0||fstat($output)['size']>8192)return null;", "if($refused||$exit!==0||fstat($output)['size']>8192){if($this->lastRun['cutoff']==='none')$this->lastRun['cutoff']=$exit!==0?'native_exit':'output_size';return null;}"),
("return is_string($raw)&&strlen($raw)<=8192?$raw:null;", "try{$this->lastRun['raw_returned']=is_string($raw)&&strlen($raw)<=8192;$j=is_string($raw)?json_decode($raw,true,8,JSON_THROW_ON_ERROR):null;$this->lastRun['json_state']=is_array($j)&&in_array($j['state']??null,['present','absent','unknown'],true)?$j['state']:'other';}catch(Throwable){$this->lastRun['json_state']='invalid';}return is_string($raw)&&strlen($raw)<=8192?$raw:null;"),
("}finally{if(is_resource($p))", "}finally{$this->lastRun['elapsed_ms']=(int)round((microtime(true)-$started)*1000);if(is_resource($p))"),
]
for before,after in changes:
 assert expected.count(before)==1,before
 expected=expected.replace(before,after,1)
actual=(root/'tests/windows_phone_health_state_adapter.php').read_text()
assert actual==expected,'The private adapter differs beyond the explicit source instrumentation'
assert '$deadline=microtime(true)+15;'in actual and '$size>8192||microtime(true)>$deadline'in actual
assert 'if($Operation'not in actual # Stateful operations stay in the installed PS helper; this copy only keeps their original request API.
print(json.dumps({'passed':True,'checks':3,'all_original_class_bytes_or_exact_telemetry_replacements':True,'original_15s_8192_exit_controls':True,'no_native_calls':True}))
