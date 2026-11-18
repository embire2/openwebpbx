'use strict';
// Execute the actual selector script against the select/option DOM contract.
// Root's installed-browser checks additionally exercise the rendered PHP page.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync('app/pbx_api_keys/keys.js','utf8');
const markup=fs.readFileSync('app/pbx_api_keys/index.php','utf8');
const printable=markup.replace(/<\?(?:php|=)[\s\S]*?\?>/g,'');
const tenantTag=printable.match(/<select\b[^>]*id="key-tenant"[^>]*>/)?.[0];
assert.ok(tenantTag);assert.equal(/\srequired(?:\s|>|=)/.test(tenantTag),false,'HTML must accept intentionally empty instance/own-PBX selections before JS starts');
const domainTag=printable.match(/<select\b[^>]*id="key-domain"[^>]*>/)?.[0];
assert.ok(domainTag);const themeOptOut=domainTag.match(/data-domain-search-init="([^"]+)"/)?.[1];assert.equal(themeOptOut,'true','Dynamic PBX selector must opt out of the stock static domain-search widget');
const theme=fs.readFileSync('themes/default/template.php','utf8');const initStart=theme.indexOf('function init_domain_search_select(select) {'),initEnd=theme.indexOf('window.sync_domain_search_select_visibility',initStart);assert.ok(initStart>0&&initEnd>initStart);
const native={dataset:{domainSearchInit:themeOptOut},style:{},options:[]};vm.runInNewContext(theme.slice(initStart,initEnd)+';init_domain_search_select(select);',{select:native,document:{createElement(){throw new Error('Stock theme must not create a stale domain widget for the API selector');}}});assert.deepEqual(native.style,{},'Stock theme hid or changed the API native selector');
let count=5;
function option(value,tenant){return {value,dataset:{tenant},hidden:false,disabled:false};}
function select(options,value,defaultDomain=''){
 let current=value;return {options,dataset:{defaultDomain},required:false,get value(){return current;},set value(value){current=value;},get selectedOptions(){return options.filter(option=>option.value===current);},addEventListener(type,handler){this.changed=handler;}};
}
function run(tenant,domain){vm.runInNewContext(source,{document:{getElementById:id=>id==='key-tenant'?tenant:domain,querySelector:()=>null}});}
let tenant=select([option(''),option('tenant-a')],'');let domain=select([option(''),option('domain-a','tenant-a')],'');run(tenant,domain);assert.equal(tenant.required,false);assert.equal(domain.options[1].disabled,true);count+=2;
tenant=select([option(''),option('tenant-a')],'','domain-a');domain=select([option(''),option('domain-a','tenant-a')],'');run(tenant,domain);assert.equal(tenant.value,'tenant-a');assert.equal(domain.value,'domain-a');assert.equal(domain.options[1].disabled,false);count+=3;
tenant=select([option('')],'','domain-own');domain=select([option(''),option('domain-own','')],'');run(tenant,domain);assert.equal(tenant.value,'');assert.equal(tenant.required,false);assert.equal(domain.value,'domain-own');count+=3;
tenant=select([option('tenant-a'),option('tenant-b')],'tenant-a');domain=select([option(''),option('domain-a','tenant-a'),option('domain-b','tenant-b')],'domain-a');run(tenant,domain);assert.equal(tenant.required,true);assert.equal(domain.options[2].hidden,true);assert.equal(domain.options[2].disabled,true);tenant.value='tenant-b';tenant.changed();assert.equal(domain.value,'');assert.equal(domain.options[1].disabled,true);assert.equal(domain.options[2].disabled,false);count+=6;
// The full-tenant button is an explicit scope/target selector, not new authority.
function presetRun(eligible,selected='tenant-a'){
 const tenant=select([option(''),option('tenant-a'),option('tenant-b')],selected);tenant.focus=()=>{tenant.focused=true;};
 const domain=select([option(''),option('domain-a','tenant-a'),option('domain-b','tenant-b')],'domain-a');
 const scopes=['pbx:read','pbx:write','calls:control','credentials:read','backups:read','backups:write','templates:read','templates:write','keys:manage'];
 const fields=[...scopes,'system:manage','reseller:manage','me:read'].map(value=>({value,checked:true}));
 const button={dataset:{tenants:JSON.stringify(eligible),scopes:JSON.stringify(scopes)},addEventListener(event,handler){this.click=handler;}};
 const feedback={textContent:''};
 vm.runInNewContext(source,{document:{getElementById:id=>({'key-tenant':tenant,'key-domain':domain,'key-preset-feedback':feedback}[id]),querySelector:()=>button,querySelectorAll:()=>fields}});
 const beforeClick=domain.value;button.click();return {tenant,domain,fields,feedback,beforeClick};
}
let preset=presetRun(['tenant-a']);assert.equal(preset.domain.value,'');assert.equal(preset.fields.filter(f=>f.checked).length,9);assert.equal(preset.fields.find(f=>f.value==='system:manage').checked,false);assert.equal(preset.fields.find(f=>f.value==='reseller:manage').checked,false);assert.match(preset.feedback.textContent,/future PBX services/);count+=5;
preset=presetRun(['tenant-a'],'tenant-b');assert.equal(preset.tenant.value,'tenant-a');assert.equal(preset.domain.value,'');count+=2;
preset=presetRun(['tenant-a','tenant-b'],'');assert.equal(preset.tenant.focused,true);assert.equal(preset.domain.value,preset.beforeClick);assert.match(preset.feedback.textContent,/Choose the tenant/);count+=3;
console.log(`PASS ${count} API key HTML/select/preset DOM controls`);
