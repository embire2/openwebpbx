// Closed QA-only browser failure categories. Raw exceptions stay private.
const kinds=['timeout','type','reference','range','security','invalid_state','not_supported','target_closed','other'];
const operations=['none','peer_lookup','stats','analyser_create','analyser_source','analyser_connect','analyser_output','spectrum','canvas_create','canvas_draw','canvas_read','complete'];
function kind(error){
  const name=typeof error?.name==='string'?error.name:'';
  const text=typeof error?.message==='string'?error.message.slice(0,512):'';
  if(name==='TimeoutError')return 'timeout';
  const type=/^page\.(?:waitForFunction|evaluate):\s*(TypeError|ReferenceError|RangeError|SecurityError|InvalidStateError|NotSupportedError):/.exec(text)?.[1]||name;
  const names={TypeError:'type',ReferenceError:'reference',RangeError:'range',SecurityError:'security',InvalidStateError:'invalid_state',NotSupportedError:'not_supported',TargetClosedError:'target_closed'};
  return Object.hasOwn(names,type)?names[type]:'other';
}
function fields(error,operation){return {kind:kind(error),operation:operations.includes(operation)?operation:'none'};}
function validate(row){return !!row&&typeof row==='object'&&!Array.isArray(row)&&Object.keys(row).length===2&&Object.hasOwn(row,'kind')&&Object.hasOwn(row,'operation')&&kinds.includes(row.kind)&&operations.includes(row.operation)?{kind:row.kind,operation:row.operation}:null;}
module.exports={fields,validate,kinds,operations};
