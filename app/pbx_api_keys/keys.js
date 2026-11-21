'use strict';
const tenant=document.getElementById('key-tenant'),domain=document.getElementById('key-domain');
function selectTenant(){for(const option of domain.options){if(!option.value)continue;option.hidden=option.dataset.tenant!==tenant.value;option.disabled=option.hidden;}if(domain.selectedOptions[0]?.disabled)domain.value='';tenant.required=![...tenant.options].some(o=>o.value==='');}
if(tenant?.dataset.defaultDomain){const selected=[...domain.options].find(o=>o.value===tenant.dataset.defaultDomain);if(selected){tenant.value=selected.dataset.tenant;domain.value=selected.value;}}
tenant?.addEventListener('change',selectTenant);if(tenant&&domain)selectTenant();
const fullTenant=document.querySelector('[data-api-tenant-admin]'),feedback=document.getElementById('key-preset-feedback');
fullTenant?.addEventListener('click',()=>{
 const eligible=JSON.parse(fullTenant.dataset.tenants),scopes=JSON.parse(fullTenant.dataset.scopes);
 if(!eligible.includes(tenant.value)){
  if(eligible.length===1)tenant.value=eligible[0];
  else {feedback.textContent='Choose the tenant to manage, then select Full tenant administration.';tenant.focus();return;}
 }
 domain.value='';selectTenant();
 for(const field of document.querySelectorAll('input[name="scopes[]"]'))field.checked=scopes.includes(field.value);
 feedback.textContent='Full administration selected for this tenant and all its current and future PBX services. Other tenants and server-wide settings are excluded.';
});
