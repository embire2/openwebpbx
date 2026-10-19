'use strict';
// Real browser DOM/polling controls. All HTTPS requests are intercepted locally.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
const directory = process.env.OPENWEB_TEST_EVIDENCE || fs.mkdtempSync('/tmp/openweb-presence-browser-');
fs.mkdirSync(directory, {recursive: true, mode: 0o700});
const domain = '00000000-0000-4000-a000-000000000001';
let checks = 0;
const check = (ok, text) => { if (!ok) throw new Error(text); checks++; };
(async () => {
 const browser = await chromium.launch({headless: true});
 try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  let requests = 0;
  let next = {domain_uuid: domain, users: {'100': {state: 'online', call_status: 'Out of office'}}};
  let code = 200;
  await page.route('https://presence.example.test/**', async route => {
   const pathname = new URL(route.request().url()).pathname;
   if (pathname === '/app/pbx_setup/user_status.php') {requests++; await route.fulfill({status: code, contentType: 'application/json', body: JSON.stringify(next)});}
   else if (pathname === '/app/pbx_setup/user-status.js') await route.fulfill({contentType: 'application/javascript', body: fs.readFileSync(path.join(root, 'app/pbx_setup/user-status.js'))});
   else if (pathname === '/app/pbx_setup/user-status.css') await route.fulfill({contentType: 'text/css', body: fs.readFileSync(path.join(root, 'app/pbx_setup/user-status.css'))});
   else await route.fulfill({contentType: 'text/html', body: `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="/app/pbx_setup/user-status.css"><script src="/app/pbx_setup/user-status.js" defer></script><style>body{margin:0;padding:16px;font:15px system-ui;background:var(--bg,#fff);color:var(--openweb-text,#26364d)}h1{font-size:24px}.setup-table-wrap{overflow:auto}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:12px;border-bottom:1px solid #8994a433}th{font-size:13px}body.dark{--bg:#172130;--openweb-text:#e6edf8;--openweb-hover:#273449}</style></head><body><h1>Users</h1><div class="setup-table-wrap" data-phone-presence="${domain}"><table><thead><tr><th>Name</th><th>Extension</th><th>Phone</th><th>Call Status</th></tr></thead><tbody><tr><td>Example User</td><td>100</td><td><span class="pbx-phone-state offline" data-phone-number="100" role="status" aria-live="polite">Offline</span></td><td><span data-call-status-number="100">Available</span></td></tr></tbody></table></div></body></html>`});
  });
  await page.clock.install();
  await page.goto('https://presence.example.test/');
  const phone = page.locator('[data-phone-number]');
  const profile = page.locator('[data-call-status-number]');
  check(await phone.textContent() === 'Offline', 'Server-rendered initial state remains visible before poll');
  const tick = async (expectedPhone, expectedProfile) => { await page.clock.fastForward(5001); await page.waitForFunction(([a,b])=>document.querySelector('[data-phone-number]').textContent===a&&document.querySelector('[data-call-status-number]').textContent===b,[expectedPhone,expectedProfile]); check(await phone.textContent() === expectedPhone && await profile.textContent() === expectedProfile,'Live phone and effective call statuses update together'); };
  await tick('Online', 'Out of office');
  check(await phone.evaluate(el=>el.classList.contains('online')), 'Online visual marker is applied');
  next.users['100'] = {state:'offline',call_status:'Away'}; await tick('Offline','Away');
  code = 503; await tick('Status unavailable','Status unavailable');
  code = 200; next = {domain_uuid:'00000000-0000-4000-a000-000000000002',users:{'100':{state:'online',call_status:'Foreign tenant data'}}}; await tick('Status unavailable','Status unavailable');
  check(!(await page.locator('body').textContent()).includes('Foreign tenant data'), 'Other PBX response cannot replace current page state');
  next = {domain_uuid:domain,users:{}}; await tick('Status unavailable','Status unavailable');
  next.users['100']={state:'invented-online',call_status:'<img src=x onerror="bad">'}; await tick('Status unavailable','<img src=x onerror="bad">');
  check(await page.locator('img').count() === 0, 'Call-status string is text, never HTML');
  await page.evaluate(()=>Object.defineProperty(document,'hidden',{get:()=>true,configurable:true}));
  const hiddenRequests = requests; await page.clock.fastForward(10001); check(requests===hiddenRequests,'Hidden page does not poll the PBX');
  await page.evaluate(()=>Object.defineProperty(document,'hidden',{get:()=>false,configurable:true}));
  next.users['100']={state:'online',call_status:'Available'}; await tick('Online','Available');
  for (const dark of [false,true]) for (const width of [1440,390,320]) {
   await page.setViewportSize({width,height:780}); await page.locator('body').evaluate((el,dark)=>el.classList.toggle('dark',dark),dark);
   check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'Responsive page does not overflow viewport');
   check(await phone.isVisible() && await profile.isVisible(),'Status labels remain rendered in responsive/light-dark table');
   if(width===320) await page.screenshot({path:path.join(directory,dark?'phone-status-dark-320.png':'phone-status-light-320.png')});
  }
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide')));
  const stoppedRequests=requests; await page.clock.fastForward(15001);check(requests===stoppedRequests,'Leaving page stops polling');
  check(errors.length===0,'No browser page errors');
  const facts={passed:checks,layouts:6,all_requests_locally_intercepted:true,no_live_server_or_customer_data_used:true};fs.writeFileSync(path.join(directory,'browser.safe.json'),JSON.stringify(facts,null,2));console.log(JSON.stringify(facts));
 } finally {await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
