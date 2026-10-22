(() => {
 'use strict';
 const content=document.querySelector('.setup-content');if(!content)return;
 const banner=document.createElement('div');banner.className='setup-message warning';banner.setAttribute('role','status');banner.hidden=true;content.prepend(banner);
 let stopped=false,timer,controller;
 const update=async()=>{
  if(stopped)return;if(document.hidden){timer=setTimeout(update,15000);return;}
  controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),10000);
  try{
   const response=await fetch('/app/pbx_phone_health/api.php',{credentials:'same-origin',cache:'no-store',headers:{Accept:'application/json'},signal:controller.signal});
   if(!response.ok)throw new Error('Unavailable');const value=await response.json();
   if(value.domain_uuid!==content.dataset.healthDomain||!value.summary)throw new Error('Wrong PBX');
   const offices=value.summary.blocked_offices,providers=value.summary.provider_failures,offline=value.summary.offline,issues=value.summary.issues;
   if(![offices,providers,offline,issues].every(n=>Number.isSafeInteger(n)&&n>=0))throw new Error('Invalid health');
   if(issues||!value.available){
    const text=document.createElement('strong');text.textContent=offices?'Office phones are blocked.':providers?'A phone provider needs attention.':offline?'Some phones are offline.':'Phone health checks are unavailable.';
    const detail=document.createElement('p');detail.textContent=`${offices} blocked offices · ${providers} provider problems · ${offline} offline phones`;
    const link=document.createElement('a');link.className='setup-button';link.href='/app/pbx_phone_health/';link.textContent='Open Phone Health';banner.replaceChildren(text,detail,link);banner.hidden=false;
   }else banner.hidden=true;
  }catch(_){banner.replaceChildren(document.createTextNode('Phone health checks are unavailable. '));const link=document.createElement('a');link.href='/app/pbx_phone_health/';link.textContent='Open Phone Health';banner.append(link);banner.hidden=false;}
  finally{clearTimeout(timeout);if(!stopped)timer=setTimeout(update,15000);}
 };
 window.addEventListener('pagehide',()=>{stopped=true;clearTimeout(timer);controller?.abort();});
 window.addEventListener('pageshow',event=>{if(event.persisted){stopped=false;update();}});update();
})();
