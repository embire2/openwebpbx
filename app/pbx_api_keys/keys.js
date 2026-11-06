'use strict';
const tenant=document.getElementById('key-tenant'),domain=document.getElementById('key-domain');
function selectTenant(){for(const option of domain.options){if(!option.value)continue;option.hidden=option.dataset.tenant!==tenant.value;option.disabled=option.hidden;}if(domain.selectedOptions[0]?.disabled)domain.value='';tenant.required=![...tenant.options].some(o=>o.value==='');}
if(tenant?.dataset.defaultDomain){const selected=[...domain.options].find(o=>o.value===tenant.dataset.defaultDomain);if(selected){tenant.value=selected.dataset.tenant;domain.value=selected.value;}}
tenant?.addEventListener('change',selectTenant);if(tenant&&domain)selectTenant();
