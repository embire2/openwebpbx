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
    if (remember) { try { localStorage.setItem('openweb-site-theme', theme); } catch {} }
  }
  let savedTheme;
  try { savedTheme = localStorage.getItem('openweb-site-theme'); } catch {}
  const preferredTheme = window.matchMedia('(prefers-color-scheme: dark)');
  setTheme(['dark', 'light'].includes(savedTheme) ? savedTheme : preferredTheme.matches ? 'dark' : 'light');
  themeButton.addEventListener('click', () => setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark', true));
  function updateClock() {
    const now = new Date();
    $('#clock-time').dateTime = now.toISOString();
    $('#clock-time').textContent = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    $('#clock-date').textContent = now.toLocaleDateString([], { day: '2-digit', month: 'short', year: 'numeric' });
  }
  updateClock(); setInterval(updateClock, 30000);

  const features = {
    updates: { title: 'Keep moving forward', icon: 'i-download', color: 'violet', description: 'Server administrators choose voluntary updates, automatic downloads or automatic installation during a daily window. Tenant administrators choose app update settings for their Android users. Each complete download is verified before installation; server updates wait for calls and preserve a recovery backup.', limits: 'Existing 1.0.3 servers and phones need a one-time 1.0.4 installation. Android may require installation permission, confirmation or a tap to reopen. Debian 13 and Windows Server 2025 are supported; Ubuntu is not included.', guide: 'docs/updates.md' },
    android: { title: 'Your extension, anywhere', icon: 'i-phone', color: 'teal', description: 'Scan your extension’s single-use QR code, make and receive calls, use in-call controls, search your company directory, return recent calls and listen to voicemail. The Android app uses native screens and connects to your own PBX.', limits: 'Android 9 or later and OpenWeb PBX 1.0.4 are required. Keep the connection notification enabled for incoming calls. Push delivery, wake-up after force-stop and broad handset/network qualification remain open. The app does not yet reproduce every 3CX client feature.', guide: 'docs/android.md' },
    calling: { title: 'Your team, connected', icon: 'i-phone', color: 'blue', description: 'Create people and extensions, choose opening hours, set up voicemail and send incoming calls to the right person, ring group or receptionist.', limits: 'Internal calling and recorded calls have passed live audio checks. Outside calls need a configured provider and qualification of your own numbers, phones and call flows.', guide: 'docs/guided-pbx-setup.md' },
    queues: { title: 'A better way to wait', icon: 'i-queue', color: 'violet', description: 'Let callers request a callback, offer one after a wait, or create it automatically. OpenWeb calls an available agent first, then connects the caller, with retries and opening-hour checks.', limits: 'Callbacks have passed internal-phone tests on Debian and Windows. Live waiting callers take priority; exact virtual queue position and outside-provider qualification remain on the roadmap.', guide: 'docs/callbacks-and-hotels.md' },
    hotel: { title: 'A warmer welcome', icon: 'i-hotel', color: 'amber', description: 'Check guests in and out, manage Clean, Dirty, Inspected and Maintenance states, set Do Not Disturb, and schedule wake-up calls that guests confirm by pressing 1.', limits: 'Room controls and confirmed wake-up calls are available. Hotel PMS connections, call charging, minibar entry and guest-scheduled wake-ups are still being developed.', guide: 'docs/callbacks-and-hotels.md' },
    tenants: { title: 'Room for every business', icon: 'i-building', color: 'teal', description: 'Invite companies into separate workspaces and give each its own PBX services, users and settings. Publish shared or company-owned templates to make new services easier to create.', limits: 'Invite-only onboarding, template encryption and tenant-isolation checks are in place. Templates cover the documented settings; broader template contents and resource controls remain on the roadmap.', guide: 'docs/tenant-services.md' },
    restore: { title: 'Bring your setup with you', icon: 'i-restore', color: 'rose', description: 'Import supported 3CX settings, recordings, voicemail and prompts into a separate OpenWeb PBX service. A Restore Report identifies missing files and behavior that needs attention.', limits: 'Native backup verification currently covers V20 Update 9 build 20.0.9.995. Other native builds require validation. Imported providers start disabled, and proprietary apps and services need replacements.', guide: 'docs/v20-restore.md' },
    desktop: { title: 'Feels like a familiar place', icon: 'i-desktop', color: 'sky', description: 'A familiar web desktop brings searchable apps, movable windows, a taskbar and light/dark themes together. Guided setup and focused Admin pages help you find your way.', limits: 'Windows Server also has a .NET 10 / WinUI 3 installation and administration manager. It opens the authenticated web Admin; the native Android calling app is available as a separate download.', guide: 'docs/installing-1.0.4.md' }
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
