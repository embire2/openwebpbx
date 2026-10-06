(() => {
  'use strict';
  const data = JSON.parse(document.getElementById('desktop-data').textContent);
  const $ = (selector) => document.querySelector(selector);
  const apps = data.apps;
  const windows = new Map();
  const preferences = (() => { try { return JSON.parse(localStorage.getItem(data.preferenceKey)) || {}; } catch { return {}; } })();
  let topZ = 10;
  let allApps = false;
  let desktopHidden = [];
  let calendarMonth = new Date();
  const savePreferences = () => { try { localStorage.setItem(data.preferenceKey, JSON.stringify(preferences)); } catch { /* Storage may be disabled. */ } };
  const announce = (text) => { $('#desktop-announcement').textContent = text; };
  const pinnedPatterns = ['/app/tenant_services/', '/app/smtp_settings/', '/core/dashboard/', '/app/extensions/', '/core/users/users.php', '/app/xml_cdr/', '/app/ivr_menus/', '/app/ring_groups/', '/app/voicemails/', '/app/call_flows/', '/app/gateways/', '/app/dialplans/', '/app/devices/', '/core/default_settings/'];
  const pinned = pinnedPatterns.map((pattern) => apps.find((app) => app.url.includes(pattern))).filter(Boolean);
  if (!pinned.length) pinned.push(...apps.slice(0, 12));
  const findApp = (pattern) => apps.find((app) => app.url.includes(pattern));

  function icon(app) {
    const result = document.createElement('span');
    result.className = 'app-icon';
    result.setAttribute('aria-hidden', 'true');
    const title = app.title.toLowerCase();
    const presets = [
      [/tenant|service|template/, 'fa-building', 'blue'],
      [/overview|dashboard|statistic/, 'fa-chart-simple', 'blue'],
      [/extension|phone|device/, 'fa-phone', 'blue'],
      [/user|profile|contact/, 'fa-user-group', 'orange'],
      [/history|record|log/, 'fa-clock-rotate-left', 'green'],
      [/ivr|dialplan|flow|destination/, 'fa-diagram-project', 'purple'],
      [/ring|conference|call center|queue/, 'fa-headset', 'pink'],
      [/mail|smtp|fax/, 'fa-envelope', 'purple'],
      [/gateway|sip|trunk|domain/, 'fa-network-wired', 'green'],
      [/setting|system|variable|permission/, 'fa-gear', 'slate']
    ];
    const preset = presets.find(([pattern]) => pattern.test(title));
    result.dataset.tone = preset ? preset[2] : ['blue', 'purple', 'green', 'orange'][app.title.length % 4];
    const symbol = document.createElement('i');
    symbol.className = preset ? `fa-solid ${preset[1]}` : (app.icon || 'fa-solid fa-cube');
    result.append(symbol);
    return result;
  }

  function appButton(app, className, showGroup = false) {
    const button = document.createElement('button');
    button.className = className;
    button.dataset.appId = app.id;
    button.append(icon(app));
    const label = document.createElement('span');
    label.textContent = app.title;
    button.append(label);
    if (showGroup) {
      const group = document.createElement('small');
      group.textContent = app.group;
      button.append(group);
    }
    button.addEventListener('click', () => openApp(app));
    return button;
  }

  pinned.slice(0, 8).forEach((app) => $('#desktop-shortcuts').append(appButton(app, 'desktop-shortcut')));
  function renderApps() {
    const term = $('#app-search').value.trim().toLowerCase();
    const collection = term || allApps ? apps : pinned;
    const matching = collection.filter((app) => `${app.title} ${app.group}`.toLowerCase().includes(term));
    if (term || allApps) matching.sort((a, b) => a.title.localeCompare(b.title));
    $('#start-apps').replaceChildren(...matching.map((app) => appButton(app, 'start-app', allApps || Boolean(term))));
    $('#apps-heading').textContent = term ? `${matching.length} results` : (allApps ? 'All applications' : 'Pinned');
    $('#no-apps').hidden = matching.length > 0;
    $('#all-apps').textContent = allApps ? 'Pinned apps' : 'All apps ›';
    $('.start-recommended').hidden = Boolean(term) || allApps;
  }
  renderApps();

  const panels = { start: $('#start-menu'), quick: $('#quick-settings'), calendar: $('#calendar-panel') };
  function hidePanels() {
    Object.values(panels).forEach((panel) => { panel.hidden = true; });
    document.querySelectorAll('[data-toggle]').forEach((button) => button.setAttribute('aria-expanded', 'false'));
  }
  function togglePanel(name, search = false) {
    const opening = panels[name].hidden;
    hidePanels();
    if (!opening && !search) return;
    panels[name].hidden = false;
    document.querySelectorAll(`[data-toggle="${name}"]`).forEach((button) => button.setAttribute('aria-expanded', 'true'));
    if (name === 'start') { renderApps(); $('#app-search').focus(); }
    else panels[name].querySelector('button')?.focus();
    if (name === 'calendar') renderCalendar();
  }
  document.querySelectorAll('[data-toggle]').forEach((button) => button.addEventListener('click', () => togglePanel(button.dataset.toggle)));
  $('#search-button').addEventListener('click', () => togglePanel('start', true));
  $('#app-search').addEventListener('input', renderApps);
  $('#app-search').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') $('#start-apps button')?.click();
  });
  $('#all-apps').addEventListener('click', () => { allApps = !allApps; renderApps(); });
  $('#overview-button').addEventListener('click', () => {
    const overview = findApp('/core/dashboard/');
    if (overview) openApp(overview); else togglePanel('start', true);
  });
  const profile = findApp('/core/users/user_profile.php');
  $('#profile-button').hidden = !profile;
  $('#profile-button').addEventListener('click', () => { if (profile) openApp(profile); });
  document.addEventListener('pointerdown', (event) => {
    if (!event.target.closest('.popover, [data-toggle], #search-button')) hidePanels();
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') { hidePanels(); $('#start-button').focus(); }
    if (event.ctrlKey && event.code === 'Space') { event.preventDefault(); togglePanel('start', true); }
    if (event.ctrlKey && event.altKey && event.key.toLowerCase() === 'd') { event.preventDefault(); showDesktop(); }
  });
  // Keep keyboard focus inside an open popover while retaining the Start button as its escape route.
  Object.values(panels).forEach((panel) => panel.addEventListener('keydown', (event) => {
    if (event.key !== 'Tab') return;
    const items = [...panel.querySelectorAll('button:not([hidden]), a, input')].filter((item) => item.getClientRects().length);
    if (!items.length) return;
    if (event.shiftKey && document.activeElement === items[0]) { event.preventDefault(); items.at(-1).focus(); }
    if (!event.shiftKey && document.activeElement === items.at(-1)) { event.preventDefault(); items[0].focus(); }
  }));

  const bounds = () => ({ width: $('#desktop').clientWidth, height: $('#desktop').clientHeight });
  function applyRect(win, rect) {
    Object.assign(win.element.style, { left: `${rect.x}px`, top: `${rect.y}px`, width: `${rect.width}px`, height: `${rect.height}px` });
  }
  function currentRect(win) {
    return { x: win.element.offsetLeft, y: win.element.offsetTop, width: win.element.offsetWidth, height: win.element.offsetHeight };
  }
  function focus(win, moveFocus = false) {
    windows.forEach((other) => { other.element.classList.remove('focused'); other.task.classList.remove('active'); other.task.setAttribute('aria-pressed', 'false'); });
    win.element.hidden = false;
    win.minimized = false;
    win.element.classList.add('focused');
    win.element.style.zIndex = ++topZ;
    win.task.classList.add('active');
    win.task.classList.remove('minimized');
    win.task.setAttribute('aria-pressed', 'true');
    desktopHidden = [];
    if (moveFocus) win.element.querySelector('.window-control').focus();
  }
  function minimize(win) {
    win.minimized = true;
    win.element.hidden = true;
    win.task.classList.remove('active');
    win.task.classList.add('minimized');
    win.task.setAttribute('aria-pressed', 'false');
    announce(`${win.app.title} minimized`);
  }
  function maximize(win, side = 'full') {
    const size = bounds();
    if (!win.maximized) win.restoreRect = currentRect(win);
    win.maximized = side;
    win.element.classList.add('maximized');
    const half = size.width / 2;
    applyRect(win, { x: side === 'right' ? half : 0, y: 0, width: side === 'full' ? size.width : half, height: size.height });
    win.maxButton.setAttribute('aria-label', `Restore ${win.app.title}`);
  }
  function restore(win) {
    win.maximized = false;
    win.element.classList.remove('maximized');
    applyRect(win, win.restoreRect);
    win.maxButton.setAttribute('aria-label', `Maximize ${win.app.title}`);
  }
  function closeWindow(win) {
    if (win.dirty && !window.confirm('This window has unsaved changes. Close it?')) return;
    win.element.remove();
    win.task.remove();
    windows.delete(win.app.id);
    announce(`${win.app.title} closed`);
    const next = [...windows.values()].filter((item) => !item.minimized).at(-1);
    if (next) focus(next); else $('#start-button').focus();
  }
  function control(label, symbol, action, className = '') {
    const button = document.createElement('button');
    button.className = `window-control ${className}`;
    button.setAttribute('aria-label', label);
    button.title = label;
    const image = document.createElement('i');
    image.className = `fa-solid ${symbol}`;
    image.setAttribute('aria-hidden', 'true');
    button.append(image);
    button.addEventListener('click', action);
    return button;
  }
  function navigate(win, url, historyIndex = null) {
    if (win.dirty && !window.confirm('This window has unsaved changes. Leave this page?')) return;
    win.dirty = false;
    win.pendingHistory = historyIndex;
    win.element.classList.add('loading');
    win.frame.src = url;
  }

  function openApp(app) {
    hidePanels();
    if (windows.has(app.id)) { focus(windows.get(app.id), true); return; }
    const element = document.createElement('section');
    element.className = 'app-window loading';
    element.setAttribute('role', 'region');
    element.setAttribute('aria-label', `${app.title} window`);
    const win = { app, element, minimized: false, maximized: false, dirty: false, history: [], historyIndex: -1, pendingHistory: null };
    const titlebar = document.createElement('header');
    titlebar.className = 'window-titlebar';
    titlebar.append(icon(app));
    const title = document.createElement('span');
    title.className = 'window-title';
    title.textContent = app.title;
    titlebar.append(title);
    const controls = document.createElement('div');
    controls.className = 'window-controls';
    const minButton = control(`Minimize ${app.title}`, 'fa-minus', () => minimize(win));
    win.maxButton = control(`Maximize ${app.title}`, 'fa-window-maximize', () => win.maximized ? restore(win) : maximize(win));
    controls.append(minButton, win.maxButton, control(`Close ${app.title}`, 'fa-xmark', () => closeWindow(win), 'close'));
    titlebar.append(controls);
    const toolbar = document.createElement('nav');
    toolbar.className = 'window-toolbar';
    toolbar.setAttribute('aria-label', `${app.title} navigation`);
    const back = control('Back', 'fa-arrow-left', () => { if (win.historyIndex > 0) navigate(win, win.history[win.historyIndex - 1], win.historyIndex - 1); });
    const forward = control('Forward', 'fa-arrow-right', () => { if (win.historyIndex < win.history.length - 1) navigate(win, win.history[win.historyIndex + 1], win.historyIndex + 1); });
    const reload = control('Refresh application', 'fa-rotate-right', () => navigate(win, win.history[win.historyIndex] || app.url, win.historyIndex));
    const path = document.createElement('span');
    path.className = 'window-path';
    path.textContent = `${app.group} / ${app.title}`;
    toolbar.append(back, forward, reload, path);
    const loading = document.createElement('div');
    loading.className = 'window-loading';
    const frame = document.createElement('iframe');
    frame.className = 'window-frame';
    frame.title = `${app.title} administration`;
    frame.name = `openweb-${app.id}`;
    win.frame = frame;
    frame.addEventListener('load', () => {
      // The iframe can emit its initial about:blank load before the app arrives.
      try { if (frame.contentWindow.location.href === 'about:blank') return; } catch {}
      element.classList.remove('loading');
      try {
        const url = new URL(frame.contentWindow.location.href);
        if (url.origin !== location.origin) return;
        if (/\/(login|logout)\.php$/.test(url.pathname)) { location.href = '/login.php'; return; }
        const pageTitle = frame.contentDocument.title.replace(/\s*[-·|]\s*OpenWeb PBX\s*$/, '').trim();
        title.textContent = pageTitle || app.title;
        path.textContent = `${app.group} / ${pageTitle || app.title}`;
        if (win.pendingHistory !== null) {
          win.historyIndex = win.pendingHistory;
          win.pendingHistory = null;
        } else if (win.history[win.historyIndex] !== url.href) {
          win.history = win.history.slice(0, win.historyIndex + 1);
          win.history.push(url.href);
          win.historyIndex = win.history.length - 1;
        }
        back.disabled = win.historyIndex <= 0;
        forward.disabled = win.historyIndex >= win.history.length - 1;
        win.dirty = false;
        const html = frame.contentDocument.documentElement;
        html.classList.add('openweb-embedded');
        html.dataset.theme = preferences.theme || 'light';
        frame.contentDocument.addEventListener('pointerdown', () => focus(win), { passive: true });
      } catch { /* Cross-origin integrations manage their own navigation. */ }
    });
    const resize = document.createElement('div');
    resize.className = 'window-resize';
    resize.setAttribute('aria-hidden', 'true');
    element.append(titlebar, toolbar, loading, frame, resize);
    const task = document.createElement('button');
    task.className = 'taskbar-button';
    task.append(icon(app));
    task.setAttribute('aria-label', `Switch to ${app.title}`);
    task.title = app.title;
    task.addEventListener('click', () => element.classList.contains('focused') && !element.hidden ? minimize(win) : focus(win, true));
    win.task = task;
    const size = bounds();
    const offset = (windows.size % 5) * 26;
    const width = Math.min(1000, size.width - 100);
    const height = Math.min(720, size.height - 90);
    applyRect(win, { x: Math.max(0, (size.width - width) / 2 + offset - 40), y: Math.max(0, 42 + offset), width, height });
    $('#window-layer').append(element);
    win.restoreRect = currentRect(win);
    $('#running-apps').append(task);
    windows.set(app.id, win);
    element.addEventListener('pointerdown', () => focus(win));
    titlebar.addEventListener('dblclick', (event) => { if (!event.target.closest('button')) win.maximized ? restore(win) : maximize(win); });
    setupPointer(win, titlebar, false);
    setupPointer(win, resize, true);
    focus(win);
    frame.src = app.url;
    announce(`${app.title} opened`);
  }

  function setupPointer(win, handle, resizing) {
    handle.addEventListener('pointerdown', (event) => {
      if (event.button !== 0 || event.target.closest('button') || matchMedia('(max-width: 680px)').matches) return;
      if (resizing && win.maximized) return;
      event.preventDefault();
      focus(win);
      if (win.maximized) restore(win);
      const rect = currentRect(win);
      const start = { x: event.clientX, y: event.clientY };
      let snap = null;
      handle.setPointerCapture(event.pointerId);
      document.body.classList.add('window-dragging');
      const move = (moveEvent) => {
        const size = bounds();
        const dx = moveEvent.clientX - start.x;
        const dy = moveEvent.clientY - start.y;
        if (resizing) {
          applyRect(win, { ...rect, width: Math.max(350, Math.min(size.width - rect.x, rect.width + dx)), height: Math.max(260, Math.min(size.height - rect.y, rect.height + dy)) });
        } else {
          applyRect(win, { ...rect, x: Math.max(-rect.width + 160, Math.min(size.width - 160, rect.x + dx)), y: Math.max(0, Math.min(size.height - 40, rect.y + dy)) });
          snap = moveEvent.clientY < 12 ? 'full' : moveEvent.clientX < 12 ? 'left' : moveEvent.clientX > size.width - 12 ? 'right' : null;
          const preview = $('#snap-preview');
          preview.hidden = !snap;
          if (snap) Object.assign(preview.style, { left: snap === 'right' ? '50%' : '0', top: '0', width: snap === 'full' ? '100%' : '50%', height: '100%' });
        }
      };
      const end = () => {
        handle.removeEventListener('pointermove', move);
        handle.removeEventListener('pointerup', end);
        handle.removeEventListener('pointercancel', end);
        document.body.classList.remove('window-dragging');
        $('#snap-preview').hidden = true;
        if (snap) maximize(win, snap);
      };
      handle.addEventListener('pointermove', move);
      handle.addEventListener('pointerup', end);
      handle.addEventListener('pointercancel', end);
    });
  }

  function showDesktop() {
    hidePanels();
    if (desktopHidden.length) {
      const restoreWindows = desktopHidden;
      desktopHidden = [];
      restoreWindows.forEach((id) => { const win = windows.get(id); if (win) focus(win); });
    } else {
      desktopHidden = [...windows.values()].filter((win) => !win.element.hidden).map((win) => win.app.id);
      windows.forEach((win) => { if (!win.element.hidden) { win.element.hidden = true; win.task.classList.remove('active'); win.task.setAttribute('aria-pressed', 'false'); } });
    }
  }
  $('#show-desktop').addEventListener('click', showDesktop);
  window.addEventListener('resize', () => windows.forEach((win) => {
    if (win.maximized) maximize(win, win.maximized);
    else {
      const rect = currentRect(win);
      const size = bounds();
      applyRect(win, { x: Math.max(0, Math.min(rect.x, size.width - 180)), y: Math.min(rect.y, Math.max(0, size.height - 80)), width: Math.min(rect.width, size.width), height: Math.min(rect.height, size.height) });
    }
  }));
  window.addEventListener('message', (event) => {
    if (event.origin !== location.origin || event.data?.type !== 'openweb-app') return;
    const win = [...windows.values()].find((item) => item.frame.contentWindow === event.source);
    if (!win) return;
    if (event.data.action === 'dirty') win.dirty = Boolean(event.data.dirty);
    if (event.data.action === 'desktop') focus(win);
    if (event.data.action === 'signout') location.href = '/logout.php';
    if (event.data.action === 'domain' && event.data.uuid && event.data.uuid !== data.domainUuid) location.reload();
  });
  window.addEventListener('beforeunload', (event) => {
    if ([...windows.values()].some((win) => win.dirty)) { event.preventDefault(); event.returnValue = ''; }
  });

  function applyTheme() {
    document.body.dataset.theme = preferences.theme || 'light';
    document.body.dataset.wallpaper = preferences.wallpaper || 'blue';
    $('#theme-toggle').setAttribute('aria-pressed', preferences.theme === 'dark' ? 'true' : 'false');
    $('#wallpaper-toggle').setAttribute('aria-pressed', preferences.wallpaper === 'violet' ? 'true' : 'false');
    windows.forEach((win) => { try { win.frame.contentDocument.documentElement.dataset.theme = preferences.theme || 'light'; } catch {} });
  }
  applyTheme();
  $('#theme-toggle').addEventListener('click', () => { preferences.theme = preferences.theme === 'dark' ? 'light' : 'dark'; savePreferences(); applyTheme(); });
  $('#wallpaper-toggle').addEventListener('click', () => { preferences.wallpaper = preferences.wallpaper === 'violet' ? 'blue' : 'violet'; savePreferences(); applyTheme(); });
  $('#fullscreen-toggle').addEventListener('click', async () => {
    try { if (document.fullscreenElement) await document.exitFullscreen(); else await document.documentElement.requestFullscreen(); }
    catch { announce('Full screen is unavailable in this browser.'); }
  });
  document.addEventListener('fullscreenchange', () => $('#fullscreen-toggle').setAttribute('aria-pressed', document.fullscreenElement ? 'true' : 'false'));

  function renderStatus(status) {
    document.body.dataset.online = String(status.online);
    $('#connection-label').textContent = status.online ? 'PBX connected' : 'PBX connection unavailable';
    $('#taskbar-status-label').textContent = status.online ? 'All systems operational' : 'Connection unavailable';
    $('#quick-status').textContent = status.online ? 'Telephony service connected' : 'Telephony service unavailable';
    document.querySelectorAll('[data-metric]').forEach((metric) => { metric.textContent = status[metric.dataset.metric] ?? '—'; });
  }
  let checkingStatus = false;
  async function refreshStatus() {
    if (checkingStatus || document.hidden) return;
    checkingStatus = true;
    try {
      const response = await fetch(data.statusUrl, { credentials: 'same-origin', cache: 'no-store' });
      if (response.redirected && new URL(response.url).pathname === '/login.php') { location.href = '/login.php'; return; }
      if (!response.ok) throw new Error('Status unavailable');
      renderStatus(await response.json());
    } catch { renderStatus({ online: false, extensions: null, registered: null, calls: null }); }
    finally { checkingStatus = false; }
  }
  renderStatus(data.status);
  $('#refresh-status').addEventListener('click', refreshStatus);
  setInterval(refreshStatus, 30000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshStatus(); });

  function updateClock() {
    const now = new Date();
    $('#clock-time').textContent = now.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    $('#clock-date').textContent = now.toLocaleDateString([], { month: 'numeric', day: 'numeric', year: 'numeric' });
    $('#clock-button').title = now.toLocaleDateString([], { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
  }
  updateClock();
  setInterval(updateClock, 1000);
  function renderCalendar() {
    const today = new Date();
    $('#calendar-date').textContent = today.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' });
    $('#calendar-month').textContent = calendarMonth.toLocaleDateString([], { month: 'long', year: 'numeric' });
    const first = new Date(calendarMonth.getFullYear(), calendarMonth.getMonth(), 1);
    const start = new Date(first); start.setDate(1 - first.getDay());
    const days = [];
    for (let i = 0; i < 42; i++) {
      const day = new Date(start); day.setDate(start.getDate() + i);
      const cell = document.createElement('span'); cell.textContent = day.getDate();
      if (day.getMonth() !== calendarMonth.getMonth()) cell.className = 'outside';
      if (day.toDateString() === today.toDateString()) { cell.className = 'today'; cell.setAttribute('aria-current', 'date'); }
      days.push(cell);
    }
    $('#calendar-days').replaceChildren(...days);
  }
  $('#calendar-prev').addEventListener('click', () => { calendarMonth = new Date(calendarMonth.getFullYear(), calendarMonth.getMonth() - 1, 1); renderCalendar(); });
  $('#calendar-next').addEventListener('click', () => { calendarMonth = new Date(calendarMonth.getFullYear(), calendarMonth.getMonth() + 1, 1); renderCalendar(); });
})();
