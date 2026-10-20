'use strict';

(() => {
  const $ = (selector) => document.querySelector(selector);
  const website = $('#desktop-window');
  const start = $('#start-menu');
  const search = $('#start-search');
  const startButton = $('#start-button');
  const announcement = $('#desktop-announcement');
  let lastWindowFocus;

  function closeStart(returnFocus = false) {
    start.hidden = true;
    startButton.setAttribute('aria-expanded', 'false');
    if (returnFocus) startButton.focus();
  }
  function showWindow(target) {
    website.hidden = false;
    document.body.classList.toggle('window-maximized', website.classList.contains('maximized'));
    $('#desktop-welcome').hidden = true;
    $('#app-button').classList.remove('minimized');
    closeStart();
    if (target) {
      const section = document.getElementById(target.replace(/^#/, ''));
      if (section) requestAnimationFrame(() => {
        section.scrollIntoView({ block: 'start' });
        const heading = section.querySelector('h1, h2') || section;
        heading.setAttribute('tabindex', '-1');
        heading.focus({ preventScroll: true });
      });
    }
  }
  function minimize() {
    lastWindowFocus = website.contains(document.activeElement) ? document.activeElement : null;
    website.hidden = true;
    document.body.classList.remove('window-maximized');
    $('#desktop-welcome').hidden = false;
    $('#app-button').classList.add('minimized');
    closeStart();
    window.scrollTo({ top: 0, behavior: 'instant' });
    $('#app-button').focus();
    announcement.textContent = 'Website minimized. Open it again from the taskbar or a desktop shortcut.';
  }
  function toggleWindow() {
    if (!website.hidden) return minimize();
    showWindow();
    if (lastWindowFocus) lastWindowFocus.focus({ preventScroll: true });
    announcement.textContent = 'OpenWeb PBX window restored.';
  }
  function toggleStart(forceOpen = false) {
    const shouldOpen = forceOpen || start.hidden;
    if (!shouldOpen) return closeStart(true);
    start.hidden = false;
    startButton.setAttribute('aria-expanded', 'true');
    search.value = '';
    filterPins();
    search.focus();
  }
  function filterPins() {
    const query = search.value.trim().toLowerCase();
    let matches = 0;
    start.querySelectorAll('[data-search]').forEach((pin) => {
      const searchable = `${pin.dataset.search} ${pin.textContent}`.toLowerCase();
      pin.hidden = !searchable.includes(query);
      if (!pin.hidden) matches++;
    });
    $('.start-empty').hidden = matches !== 0;
  }
  startButton.addEventListener('click', () => toggleStart());
  $('#search-button').addEventListener('click', () => toggleStart(true));
  search.addEventListener('input', filterPins);
  search.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      const first = start.querySelector('[data-search]:not([hidden])');
      if (first) first.click();
    }
  });
  document.addEventListener('click', (event) => {
    if (!start.hidden && !start.contains(event.target) && !event.target.closest('#start-button, #search-button')) closeStart();
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !start.hidden) closeStart(true);
    if (event.ctrlKey && event.code === 'Space' && !$('#feature-dialog').open) {
      event.preventDefault(); toggleStart();
    }
  });
  document.querySelectorAll('[data-open-window]').forEach((link) => link.addEventListener('click', (event) => {
    event.preventDefault();
    showWindow(link.getAttribute('href'));
    history.replaceState(null, '', link.getAttribute('href'));
  }));
  $('#app-button').addEventListener('click', toggleWindow);
  $('#show-desktop').addEventListener('click', toggleWindow);
  $('#minimize-window').addEventListener('click', minimize);
  $('#close-window').addEventListener('click', minimize);
  $('#restore-window').addEventListener('click', () => showWindow('#welcome'));
  function maximize() {
    const on = website.classList.toggle('maximized');
    document.body.classList.toggle('window-maximized', on);
    $('#maximize-window').setAttribute('aria-pressed', String(on));
    $('#maximize-window').setAttribute('aria-label', on ? 'Restore website window size' : 'Maximize website window');
    $('#maximize-window').title = on ? 'Restore' : 'Maximize';
    website.style.translate = '';
  }
  $('#maximize-window').addEventListener('click', maximize);
  $('#window-titlebar').addEventListener('dblclick', (event) => {
    if (!event.target.closest('button')) maximize();
  });
  let drag;
  const titlebar = $('#window-titlebar');
  titlebar.addEventListener('pointerdown', (event) => {
    if (event.button !== 0 || event.target.closest('button') || window.innerWidth < 800 || website.classList.contains('maximized')) return;
    const previous = (website.style.translate || '0px 0px').split(' ').map(parseFloat);
    drag = { x: event.clientX, y: event.clientY, previous };
    titlebar.setPointerCapture(event.pointerId);
    titlebar.classList.add('is-dragging');
  });
  titlebar.addEventListener('pointermove', (event) => {
    if (!drag) return;
    const x = Math.min(20, Math.max(-40, drag.previous[0] + event.clientX - drag.x));
    const y = Math.min(110, Math.max(0, drag.previous[1] + event.clientY - drag.y));
    website.style.translate = `${x}px ${y}px`;
  });
  function endDrag() { drag = null; titlebar.classList.remove('is-dragging'); }
  titlebar.addEventListener('pointerup', endDrag);
  titlebar.addEventListener('pointercancel', endDrag);
  titlebar.addEventListener('lostpointercapture', endDrag);

  const themeButton = $('#theme-button');
  function setTheme(theme, remember = false) {
    document.documentElement.dataset.theme = theme;
    const dark = theme === 'dark';
    themeButton.setAttribute('aria-label', dark ? 'Switch to light theme' : 'Switch to dark theme');
    themeButton.setAttribute('title', dark ? 'Switch to light theme' : 'Switch to dark theme');
    themeButton.querySelector('use').setAttribute('href', dark ? '#i-sun' : '#i-moon');
    $('meta[name="theme-color"]').content = dark ? '#172e46' : '#dceafa';
    if (remember) window.OpenWebPrivacy?.rememberTheme(theme);
  }
  const savedTheme = window.OpenWebPrivacy?.getTheme();
  const preferredTheme = window.matchMedia('(prefers-color-scheme: dark)');
  setTheme(['dark', 'light'].includes(savedTheme) ? savedTheme : preferredTheme.matches ? 'dark' : 'light');
  window.addEventListener('openweb:privacychange', () => {
    const saved = window.OpenWebPrivacy?.getTheme();
    setTheme(saved || (preferredTheme.matches ? 'dark' : 'light'));
  });
  themeButton.addEventListener('click', () => setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark', true));
  function updateClock() {
    const now = new Date();
    $('#clock-time').dateTime = now.toISOString();
    $('#clock-time').textContent = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    $('#clock-date').textContent = now.toLocaleDateString([], { day: '2-digit', month: 'short', year: 'numeric' });
  }
  updateClock(); setInterval(updateClock, 30000);

  const features = {
    "calling": {"title": "Your team, connected", "icon": "i-phone", "color": "blue", "description": "Create extensions, voicemail and incoming routes. Dial 121 from your authenticated extension to open your own mailbox without a PIN. Nathaniel supplies the default UK voice prompts and reads the GMT+2 time on 1026. Your custom recordings are preserved. Add a provider through a guided form and review first calls before moving a connection.", "limits": "New providers and numbers start off. Native internal and fixture-provider calls have passed audio checks; qualify your own provider and numbers before a cutover.", "guide": "docs/core-calling.md"},
    "queues": {"title": "A better way to wait", "icon": "i-queue", "color": "violet", "description": "Choose queue capacity, ringing priorities, position announcements and overflow. Offer agent-first callbacks with Live Callers First or Keep Original Queue Position. Follow waiting callers, agent state and finished results on the wallboard and queue reports.", "limits": "Wait estimates are approximate. Real-carrier delivery and representative phones remain qualification work. This release has in-page target alerts rather than external alert delivery.", "guide": "docs/core-calling.md"},
    "hotel": {"title": "A warmer welcome", "icon": "i-hotel", "color": "amber", "description": "Check guests in and out, manage room status and Do Not Disturb, and schedule wake-up calls confirmed by pressing 1.", "limits": "PMS integration, call charging, minibar entry and guest-scheduled wake-ups remain on the roadmap.", "guide": "docs/callbacks-and-hotels.md"},
    "tenants": {"title": "Room for every business", "icon": "i-building", "color": "teal", "description": "Invite companies to separate workspaces, create their PBX services and publish shared or company-owned setup templates. One PostgreSQL database serves all tenants in an installation; system mail uses the global relay.", "limits": "Broader template coverage and resource controls remain on the roadmap.", "guide": "docs/tenant-services.md"},
    "restore": {"title": "Bring your setup with you", "icon": "i-restore", "color": "rose", "description": "Restore supported 3CX settings and media with original phone credentials, mapped ring groups, queue order and call routes. Prepare each phone’s domain change, keep its original credentials and track the actual phone checks. Connect a reviewed provider with its saved incoming numbers together.", "limits": "Native backup verification covers V20 Update 9 build 20.0.9.995. Other builds need validation. Imported providers start off; physical phone and carrier checks are required. Use OpenWebPBX Free Phone.", "guide": "docs/desk-phone-handover.md"},
    "desktop": {"title": "Feels like a familiar place", "icon": "i-desktop", "color": "sky", "description": "Search apps, move administration windows and use a taskbar with light and dark themes. Guided setup and focused Admin pages use clear controls.", "limits": "The previous Windows Server download includes an administration manager. The separate native Windows calling client is planned.", "guide": "docs/installing-1.0.16.md"},
    "android": {"title": "Your extension, anywhere", "icon": "i-phone", "color": "teal", "description": "Version 1.0.18 requires each saved account to confirm its registered openwebpbx.com tenant address. Connect new accounts by QR or setup file; app-password sign-in is available only on supporting servers. Keep your credentials and personal settings when updating. Use visible Call Hold / Resume Call with music, including three-way calls. Choose your theme, ringtone, start page, contacts order and keypad vibration in native Settings. Make and receive calls, blind or attended transfer, answer a second call and merge a three-way conversation. Change availability, pause or leave queues, search contacts, return recent calls and listen to voicemail. Optional incoming wake-up uses an open-source native connector and server-generated keys; your own Firebase project is not required. The app retains optional native video between colleagues on a matching PBX, with audio-only answers and explicit camera controls. A call or video request never switches your camera on automatically.", "limits": "Android 9 or later is required. Android 1.0.18 needs ready tenant HTTPS and phone API support; stock 1.0.16 servers must prepare those first. Video needs the 1.0.16 PBX. SIP desk-phone settings are unaffected. Camera restart can briefly pause sound or pictures; a software test recorded one 833 ms transition. Locked/idle physical handset wake-up, physical network handover and broader handset qualification remain open. Force-stopping an app prevents background delivery. Google Play approval is pending.", "guide": "docs/android-video.md"},
    "meet": {"title": "Meet, face to face", "icon": "i-desktop", "color": "blue", "description": "Included in Debian 13 version 1.0.16: create an audio or video meeting, share a private link or calendar invitation and admit guests from the waiting room. Registered extensions can dial the meeting number. Hosts can mute, remove, lock and end the room; participants choose whether to use a camera or share a screen.", "limits": "Up to 25 people can join; capacity depends on the server and connection. Software browser and phone media checks passed. Physical cameras, restrictive networks, capacity testing, recording and Windows qualification remain open.", "guide": "docs/meet.md"},
    "updates": {"title": "Keep moving forward", "icon": "i-download", "color": "violet", "description": "Choose voluntary downloads or managed update policies. Server updates verify complete downloads, wait for calls and retain a recovery snapshot. An instance administrator can require a minimum Android version for every tenant; tenant preferences apply to later releases.", "limits": "New server releases target Debian 13. Android can require installation confirmation and a tap to reopen; Google Play installation follows store rules.", "guide": "docs/updates.md"},
    "hours": {"title": "Open when you need to be", "icon": "i-map", "color": "teal", "description": "Set several opening periods, overnight hours, breaks and dated holidays in a department timezone. Temporarily open or close for a chosen period and preview a user or incoming-number route.", "limits": "User availability and forwarding still apply after an incoming route selects its destination. Use the preview and actual call checks when changing your routes.", "guide": "docs/core-calling.md"},
    "switchboard": {"title": "Give reception a clear view", "icon": "i-desktop", "color": "blue", "description": "See this PBX’s live calls and searchable user availability. Hold, resume, transfer, pick up, park and retrieve calls with enabled connected phones. Shared parking is explicitly enabled per PBX.", "limits": "Actions require the relevant permissions and a live call. These controls use the connected phone; the web switchboard is not a browser softphone.", "guide": "docs/core-calling.md"},
    "backups": {"title": "Keep a way back", "icon": "i-restore", "color": "rose", "description": "Schedule encrypted instance backups, retain the chosen number of snapshots and include voicemail and recordings. Download verified backups and restore onto a clean Debian server using the documented procedure.", "limits": "Instance administration controls backups. Preserve the recovery password separately. A restore onto a clean Debian server has passed; off-site storage requires your own destination.", "guide": "docs/backups.md"},
    "windows-client": {"title": "A native Windows phone, next", "icon": "i-desktop", "color": "sky", "description": "The plan is a C#/.NET 10 and WinUI 3 calling client with contacts, transfers, headset controls and availability. An emailed one-use setup file will connect a user without scanning a QR code.", "limits": "This is a development plan. No native Windows softphone is included in 1.0.16; the earlier WinUI administration manager is a separate application.", "guide": "docs/windows-client-plan.md"}
  };
  const dialog = $('#feature-dialog');
  dialog.setAttribute('aria-labelledby', 'dialog-heading');
  dialog.setAttribute('aria-describedby', 'dialog-description');
  document.querySelectorAll('[data-feature]').forEach((card) => card.addEventListener('click', () => {
    const feature = features[card.dataset.feature];
    $('#dialog-heading').textContent = feature.title;
    $('#dialog-description').textContent = feature.description;
    $('#dialog-limits').textContent = feature.limits;
    $('#dialog-link').href = `https://github.com/embire2/openwebpbx/blob/customization/${feature.guide}`;
    $('#dialog-icon').className = `feature-icon ${feature.color}`;
    const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', `#${feature.icon}`);
    icon.append(use);
    $('#dialog-icon').replaceChildren(icon);
    closeStart(); dialog.showModal();
  }));
  $('#close-dialog').addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) {
      const rect = dialog.getBoundingClientRect();
      if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close();
    }
  });
})();
