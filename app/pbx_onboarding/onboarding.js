'use strict';
(() => {
 const wizard=document.querySelector('[data-onboarding]');
 if(!wizard||wizard.dataset.pending!=='true'||!wizard.dataset.service)return;
 const message=wizard.querySelector('[data-onboarding-message]');
 const help=wizard.querySelector('[data-poll-help]');
 const done=wizard.querySelector('[data-finished]');
 const badge=wizard.querySelector('[data-onboarding-badge]');
 const progress=wizard.querySelector('[data-progress]');
 let busy=false;
 const address=new URL(location.href);address.search='';address.searchParams.set('service_uuid',wizard.dataset.service);address.searchParams.set('format','json');
 async function check(){
  if(busy||document.hidden)return;busy=true;
  const controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),10000);
  try{
   const response=await fetch(address,{credentials:'same-origin',cache:'no-store',headers:{Accept:'application/json'},signal:controller.signal});
   if(!response.ok)throw new Error('Status unavailable');
   const state=await response.json();
   if(state.service_uuid!==wizard.dataset.service||typeof state.ready!=='boolean')throw new Error('Status unavailable');
   if(message&&typeof state.message==='string')message.textContent=state.message;
   if(help)help.hidden=true;
   const connect=wizard.querySelector('[data-connect]');if(connect)connect.disabled=state.identity_ready!==true||state.can_request_registration!==true;
   if(state.needs_email_verification&&wizard.dataset.needsEmail!=='true'||state.needs_sign_in&&wizard.dataset.needsSignin!=='true'){location.replace('/app/pbx_onboarding/?service_uuid='+encodeURIComponent(wizard.dataset.service));return;}
   if(state.ready){
    const url=new URL(state.url);
    if(url.protocol!=='https:'||!/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\.openwebpbx\.com$/.test(url.hostname)||url.username||url.password||url.port||url.pathname!=='/'||url.search||url.hash)throw new Error('Address unavailable');
    const link=wizard.querySelector('[data-tenant-address]');if(link){link.href=url.href;link.textContent=url.origin;}
    if(done)done.hidden=false;if(progress)progress.hidden=true;if(badge){badge.textContent='Connected';badge.classList.add('done');}
    wizard.querySelectorAll('[data-onboarding-stage]').forEach(node=>{node.hidden=true;});
    wizard.querySelectorAll('.onboarding-steps li').forEach((node,index)=>{node.classList.remove('current');node.classList.toggle('complete',index<3);node.removeAttribute('aria-current');if(index===3){node.classList.add('current');node.setAttribute('aria-current','step');}});
    wizard.dataset.pending='false';return;
   }
  }catch{if(help)help.hidden=false;}
  finally{clearTimeout(timeout);busy=false;if(wizard.dataset.pending==='true')setTimeout(check,5000);}
 }
 setTimeout(check,1500);
})();
