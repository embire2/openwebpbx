(() => {
 'use strict';
 const root=document.querySelector('[data-phone-health]');if(!root)return;
 const byId=id=>document.getElementById(id);
 const node=(tag,text,className)=>{const el=document.createElement(tag);if(text!==undefined)el.textContent=text;if(className)el.className=className;return el;};
 const message=byId('health-message'),dialog=byId('health-recovery');
 let timer,controller,stopped=false,busy=false,selected=null,phones=[],settingsEdited=false,pollError=false;
 const tell=(text,error=false)=>{message.textContent=text;message.classList.toggle('error',error);message.hidden=false;};
 const empty=(id,text)=>byId(id).replaceChildren(node('p',text,'health-empty'));
 const date=value=>{const stamp=new Date(value);return value&&!Number.isNaN(stamp.valueOf())?stamp.toLocaleString():'Not yet observed';};
 const badge=(state,label)=>{const tone=({failed:'danger',connecting:'warning',configured:'success',off:'disabled'})[state]||state;return node('span',label,'health-state '+(['online','offline','disabled','unavailable','success','warning','danger'].includes(tone)?tone:'unavailable'));};
 const row=(title,reason,nextStep)=>{const el=node('article',undefined,'health-row'),body=node('div');body.append(node('h3',title),node('p',reason));if(nextStep)body.append(node('small',nextStep));el.append(body);return el;};
 const showPhones=()=>{
  const filter=byId('health-search').value.trim().toLocaleLowerCase();
  const list=phones.filter(p=>(p.number+' '+p.name).toLocaleLowerCase().includes(filter)).map(p=>{
   const el=row(p.number+' · '+p.name,p.reason,p.next_step),body=el.firstChild;
   body.append(node('p','Call status: '+p.call_status));
   body.append(node('small','Last desk phone connection: '+date(p.last_seen)));
   el.append(badge(p.state,p.label));return el;
  });byId('health-phones').replaceChildren(...list);if(!list.length)empty('health-phones',filter?'No matching phones.':'No phones have been added to this PBX.');
 };
 const render=value=>{
  if(value.domain_uuid!==root.dataset.phoneHealth||!value.summary||!Array.isArray(value.phones)||!Array.isArray(value.providers)||!Array.isArray(value.office_blocks)||!Array.isArray(value.issues))throw new Error('Your PBX changed. Refresh this page.');
  if(value.phones.some(p=>typeof p.number!=='string'||typeof p.name!=='string'))throw new Error('Phone status is incomplete.');
  root.querySelectorAll('[data-count]').forEach(el=>{const count=value.summary[el.dataset.count];el.textContent=Number.isSafeInteger(count)&&count>=0?String(count):'—';});
  byId('health-checked').textContent=(value.available?'Checked: ':'Some checks are unavailable · ')+date(value.checked_at);
  byId('health-issues').replaceChildren(...value.issues.map(issue=>row(issue.title,issue.message,'First noticed: '+date(issue.first_seen))));
  if(!value.issues.length)empty('health-issues',value.available?'No current problems found.':'Live checks are unavailable. Last-known blocks remain listed below.');
  const blocks=value.office_blocks.map(block=>{
   const affected=Array.isArray(block.affected_numbers)?block.affected_numbers.join(', '):'';
   const el=row('Office '+(block.source_address||'address withheld'),block.reason,'Affected extensions: '+affected+' · '+date(block.blocked_at));
   if(block.can_recover===true&&typeof block.block_uuid==='string'&&typeof block.revision==='string'){
    const button=node('button','Review recovery','setup-button');button.type='button';button.addEventListener('click',()=>{
     selected={block_uuid:block.block_uuid,revision:block.revision};
     byId('health-recovery-description').textContent='Remove the phone sign-in block for '+block.source_address+' affecting '+affected+'?';
     byId('health-confirm').checked=false;byId('health-recover-submit').disabled=true;dialog.showModal();
    });el.append(button);
   }else el.firstChild.append(node('p',block.restriction||'Ask your instance administrator to review this block.'));
   return el;
  });byId('health-blocks').replaceChildren(...blocks);if(!blocks.length)empty('health-blocks','No active blocks are linked to a verified office for this PBX.');
  const recoveries=Array.isArray(value.recoveries)?value.recoveries:[];
  const recoveryLabels={pending:'Waiting for confirmation',acknowledged:'Block removed',refused:'Review required',dispatch_failed:'Not confirmed'};
  byId('health-recoveries').replaceChildren(...recoveries.map(recovery=>{
   const el=row('Office '+(recovery.source_address||'address withheld'),'Requested: '+date(recovery.requested_at),recovery.acknowledged_at?'Confirmed: '+date(recovery.acknowledged_at):'');
   el.append(badge(recovery.status==='acknowledged'?'success':'warning',recoveryLabels[recovery.status]||'Status unavailable'));return el;
  }));if(!recoveries.length)empty('health-recoveries','No recovery requests have been made for this PBX.');
  phones=value.phones;showPhones();
  byId('health-providers').replaceChildren(...value.providers.map(p=>{const el=row(p.name,p.reason,p.next_step);el.append(badge(p.state,p.label));return el;}));
  if(!value.providers.length)empty('health-providers','No phone providers have been added.');
  const settings=value.alert_settings;
  if(settings&&typeof settings.alerts_enabled==='boolean'){
   if(!settingsEdited)byId('health-alerts-enabled').checked=settings.alerts_enabled;
   byId('health-alerts-enabled').disabled=false;byId('health-alert-settings').querySelector('button').disabled=false;
  }
 };
 const request=async(data)=>{
  const body=new URLSearchParams({...data,[root.dataset.tokenName]:root.dataset.tokenValue});
  const abort=new AbortController(),timeout=setTimeout(()=>abort.abort(),15000);
  try{const response=await fetch('/app/pbx_phone_health/api.php',{method:'POST',credentials:'same-origin',cache:'no-store',headers:{Accept:'application/json'},body,signal:abort.signal});const result=await response.json();if(!response.ok)throw new Error(result.error||'The request could not be completed.');return result;}
  finally{clearTimeout(timeout);}
 };
 const update=async()=>{
  clearTimeout(timer);if(stopped||busy)return;if(document.hidden){timer=setTimeout(update,15000);return;}
  busy=true;byId('health-refresh').disabled=true;controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),12000);
  try{const response=await fetch('/app/pbx_phone_health/api.php',{credentials:'same-origin',cache:'no-store',headers:{Accept:'application/json'},signal:controller.signal});if(!response.ok)throw new Error('Phone health is unavailable. Refresh and sign in again if needed.');render(await response.json());if(pollError){message.hidden=true;pollError=false;}}
  catch(error){byId('health-checked').textContent='Live checks unavailable';root.querySelectorAll('[data-count]').forEach(el=>el.textContent='—');tell(error.name==='AbortError'?'The check took too long. We will try again.':error.message,true);pollError=true;byId('health-blocks').replaceChildren(node('p','Refresh to review current recovery options.'));}
  finally{clearTimeout(timeout);busy=false;byId('health-refresh').disabled=false;if(!stopped)timer=setTimeout(update,15000);}
 };
 byId('health-refresh').addEventListener('click',update);byId('health-search').addEventListener('input',showPhones);
 byId('health-confirm').addEventListener('change',event=>byId('health-recover-submit').disabled=!event.target.checked);
 const close=()=>{dialog.close();selected=null;};byId('health-recovery-cancel').addEventListener('click',close);dialog.addEventListener('close',()=>selected=null);
 byId('health-recovery-form').addEventListener('submit',async event=>{
  event.preventDefault();if(!selected||!byId('health-confirm').checked)return;
  byId('health-recover-submit').disabled=true;
  try{const result=await request({action:'recover',...selected,confirmed:'1'});close();tell(result.message||'Recovery requested. Waiting for the security service to confirm.');await update();}
  catch(error){close();tell(error.message,true);await update();}
 });
 byId('health-alerts-enabled').addEventListener('change',()=>settingsEdited=true);
 byId('health-alert-settings').addEventListener('submit',async event=>{
  event.preventDefault();const button=event.currentTarget.querySelector('button');button.disabled=true;
  try{const result=await request({action:'alerts',enabled:byId('health-alerts-enabled').checked?'1':'0'});settingsEdited=false;tell(result.message);}
  catch(error){tell(error.message,true);}finally{button.disabled=false;}
 });
 window.addEventListener('pagehide',()=>{stopped=true;clearTimeout(timer);controller?.abort();});
 window.addEventListener('pageshow',event=>{if(event.persisted){stopped=false;update();}});
 update();
})();
