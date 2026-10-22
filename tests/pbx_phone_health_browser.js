'use strict';
// Exercise actual shipped UI with local-only responses; never unblock a real office.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..');let checks=0;
const check=(ok,label)=>{if(!ok)throw new Error(label);checks++;};
const domain='00000000-0000-4000-a000-000000000001';
const block={block_uuid:'00000000-0000-4000-a000-000000000002',source_address:'192.0.2.20',affected_numbers:['100'],blocked_at:new Date().toISOString(),reason:'Repeated sign-in failures blocked this office.',can_recover:true,revision:'a'.repeat(64),restriction:''};
const initial={domain_uuid:domain,checked_at:new Date().toISOString(),available:true,summary:{online:1,offline:1,blocked_offices:1,provider_failures:1,issues:2},phones:[{number:'100',name:'Example User',state:'offline',label:'Offline',reason:'Office blocked',next_step:'Review the block',call_status:'Available',last_seen:new Date().toISOString()},{number:'101',name:'<img src=x onerror="bad">',state:'online',label:'Online',reason:'Connected',next_step:'Test sound',call_status:'Away',last_seen:null}],providers:[{id:'test',name:'Example Provider',state:'failed',label:'Connection failed',reason:'No connection',next_step:'Check Voice & Chat'}],office_blocks:[block],issues:[{title:'Office blocked',message:'A security block affects one phone.',first_seen:new Date().toISOString()}],alert_settings:{alerts_enabled:false}};
(async()=>{
 const browser=await chromium.launch({headless:true});
 try{
  const page=await browser.newPage();let current=structuredClone(initial),status=200,posts=[],gets=0,postStatus=200,postReply={status:'pending',message:'Recovery requested; waiting for security confirmation.'};const errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  const source=fs.readFileSync(path.join(root,'app/pbx_phone_health/index.php'),'utf8');let html=source.slice(source.indexOf('?>')+2).split('<?php require_once')[0];
  html=html.replace('<script src="/app/pbx_phone_health/health.js?v=1" defer></script>','<script src="/app/pbx_phone_health/health.js?v=1" defer></script>').replace(/<\?= \$e\(\$_SESSION\['domain_uuid'\]\) \?>/g,domain).replace(/<\?= \$e\(\$token\['name'\]\) \?>/g,'test_token').replace(/<\?= \$e\(\$token\['hash'\]\) \?>/g,'test_hash');
  check(!html.includes('<?'),'Fixture uses complete actual shipped HTML');
  await page.route('https://health.example.test/**',async route=>{
   const url=new URL(route.request().url()),file=url.pathname;
   if(file==='/app/pbx_phone_health/api.php'){
    if(route.request().method()==='POST'){posts.push(new URLSearchParams(route.request().postData()));await route.fulfill({status:postStatus,contentType:'application/json',body:JSON.stringify(postReply)});}
    else{gets++;await route.fulfill({status,contentType:'application/json',body:JSON.stringify(current)});}
   }else if(file.endsWith('.js')||file.endsWith('.css'))await route.fulfill({contentType:file.endsWith('.js')?'application/javascript':'text/css',body:fs.readFileSync(path.join(root,file))});
   else await route.fulfill({contentType:'text/html',body:'<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style>body{margin:0;font:14px system-ui;background:var(--bg,#eff4fa);color:var(--openweb-text,#26364d)}html[data-theme=dark]{--bg:#152033;--openweb-surface:#202d42;--openweb-text:#e7eef8;--openweb-line:#3a4b66}</style></head><body>'+(file==='/admin'?'<div class="setup-content" data-health-domain="'+domain+'"></div><script src="/app/pbx_phone_health/admin-alerts.js"></script>':html)+'</body></html>'});
  });
  await page.clock.install();await page.goto('https://health.example.test/');await page.getByText('Example User',{exact:false}).waitFor();
  check(await page.locator('[data-count=blocked_offices]').textContent()==='1','Office block count visible');
  check(await page.locator('#health-phones img').count()===0,'Display name rendered as text');
  await page.getByRole('button',{name:'Review recovery'}).click();
  check(await page.locator('#health-recovery').isVisible(),'Recovery opens explicit confirmation');
  check(await page.locator('#health-recover-submit').isDisabled(),'Unconfirmed request cannot submit');
  await page.getByRole('button',{name:'Cancel',exact:true}).click();check(posts.length===0,'Cancel makes no recovery request');
  await page.getByRole('button',{name:'Review recovery'}).click();await page.locator('#health-confirm').check();await page.locator('#health-recover-submit').click();await page.waitForFunction(()=>document.querySelector('#health-message').textContent.includes('waiting for security'));
  check(posts.length===1&&posts[0].get('action')==='recover'&&posts[0].get('confirmed')==='1'&&posts[0].get('revision')===block.revision,'Confirmed request pins exact block revision');
  check(posts[0].get('test_token')==='test_hash'&&!posts[0].has('domain_uuid'),'POST carries CSRF and cannot select tenant');
  check((await page.locator('#health-message').textContent()).includes('waiting'),'Dispatch is not displayed as completed recovery');
  current.office_blocks[0].can_recover=false;current.office_blocks[0].restriction='Shared with another PBX.';await page.getByRole('button',{name:'Refresh now'}).click();await page.getByText('Shared with another PBX.').waitFor();check(await page.getByRole('button',{name:'Review recovery'}).count()===0,'Unsafe block has no recovery control');
  await page.locator('#health-search').fill('100');check(await page.locator('#health-phones article').count()===1,'Phone search filters exact current list');await page.locator('#health-search').fill('');
  postReply={message:'Alert settings saved.'};await page.locator('#health-alerts-enabled').check();await page.getByRole('button',{name:'Save alerts'}).click();await page.getByText('Alert settings saved.',{exact:true}).waitFor();check(posts.at(-1).get('action')==='alerts'&&posts.at(-1).get('enabled')==='1','Optional email setting saves through protected endpoint');
  current.domain_uuid='foreign';current.phones[0].name='Foreign secret';await page.getByRole('button',{name:'Refresh now'}).click();await page.getByText('Your PBX changed. Refresh this page.',{exact:true}).waitFor();check(!(await page.locator('body').textContent()).includes('Foreign secret'),'Foreign-tenant response never renders');
  check(await page.getByRole('button',{name:'Review recovery'}).count()===0,'Failed check removes stale recovery buttons');
  current=structuredClone(initial);await page.getByRole('button',{name:'Refresh now'}).click();await page.getByRole('button',{name:'Review recovery'}).waitFor();
  postStatus=409;postReply={error:'This office block changed. Refresh before requesting recovery.'};await page.getByRole('button',{name:'Review recovery'}).click();await page.locator('#health-confirm').check();await page.locator('#health-recover-submit').click();await page.getByText(postReply.error,{exact:true}).waitFor();check(!await page.locator('#health-recovery').isVisible(),'Stale revision error closes dialog and requires new review');
  status=503;await page.getByRole('button',{name:'Refresh now'}).click();await page.waitForFunction(()=>document.querySelector('[data-count=online]').textContent==='—');check(await page.locator('[data-count=online]').textContent()==='—','Unavailable status is not falsely zero/offline');
  status=200;current.office_blocks=[];await page.getByRole('button',{name:'Refresh now'}).click();await page.getByText('No active blocks are linked to a verified office for this PBX.').waitFor();
  const output=process.env.OPENWEB_TEST_EVIDENCE;if(output)fs.mkdirSync(output,{recursive:true,mode:0o700});
  for(const theme of ['light','dark'])for(const width of [1440,390,320]){
   await page.setViewportSize({width,height:900});await page.evaluate(theme=>document.documentElement.dataset.theme=theme,theme);
   check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'Responsive page fits '+theme+' '+width);
   check(await page.getByRole('heading',{name:'Phone Health & Recovery'}).isVisible(),'Heading remains visible');
   if(output&&((theme==='light'&&width===1440)||(theme==='dark'&&width===320)))await page.screenshot({path:path.join(output,'health-'+theme+'-'+width+'.png'),fullPage:true});
  }
  await page.evaluate(()=>Object.defineProperty(document,'hidden',{get:()=>true,configurable:true}));const before=gets;await page.clock.fastForward(30001);check(gets===before,'Hidden page pauses polling');
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide')));await page.clock.fastForward(30001);check(gets===before,'Leaving page stops polling');const resumed=page.waitForResponse(response=>response.url().endsWith('/api.php'));await page.evaluate(()=>{Object.defineProperty(document,'hidden',{get:()=>false,configurable:true});window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));});await resumed;check(gets>before,'Cached-page return resumes live checks');check(errors.length===0,'No browser errors');
  current=structuredClone(initial);await page.goto('https://health.example.test/admin');await page.getByText('Office phones are blocked.',{exact:true}).waitFor();check(await page.getByRole('link',{name:'Open Phone Health'}).getAttribute('href')==='/app/pbx_phone_health/','Dashboard block warning has direct recovery entry');
  const poll=async()=>{const response=page.waitForResponse(r=>r.url().endsWith('/api.php'));await page.clock.fastForward(15001);await response;};
  current={...current,available:true,summary:{online:2,offline:15,blocked_offices:0,provider_failures:0,issues:0}};await poll();await page.waitForFunction(()=>document.querySelector('.setup-message').hidden);check(await page.locator('.setup-message').isHidden(),'Unprovisioned offline phones do not create dashboard outage banner');
  current.domain_uuid='foreign';current.summary.blocked_offices=25;await poll();await page.getByText('Phone health checks are unavailable.',{exact:false}).waitFor();check(!(await page.locator('body').textContent()).includes('25 blocked'),'Dashboard rejects foreign PBX status');
  const stoppedAt=gets;await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide')));await page.clock.fastForward(30001);check(gets===stoppedAt,'Dashboard polling stops on leave');
  current=structuredClone(initial);const back=page.waitForResponse(r=>r.url().endsWith('/api.php'));await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));await back;await page.getByText('Office phones are blocked.',{exact:true}).waitFor();check(gets>stoppedAt,'Dashboard resumes after cached-page return');check(errors.length===0,'Dashboard has no browser errors');
  console.log(JSON.stringify({passed:checks,layouts:6,local_only:true}));
 }finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
