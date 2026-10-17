'use strict';

// Only the privacy choice is read before consent. Appearance is optional everywhere.
(() => {
  const KEY = 'openweb-site-consent';
  const THEME = 'openweb-site-theme';
  const VERSION = 1;
  const LIFETIME = 180 * 24 * 60 * 60 * 1000;
  let memory = null;
  let dialog;
  let banner;
  let priorFocus;
  const storage = {
    get(key) { try { return localStorage.getItem(key); } catch { return null; } },
    set(key, value) { try { localStorage.setItem(key, value); } catch {} },
    remove(key) { try { localStorage.removeItem(key); } catch {} }
  };
  function valid(raw) {
    try {
      const value = JSON.parse(raw);
      return value && value.version === VERSION && typeof value.appearance === 'boolean' &&
        Number.isFinite(value.chosenAt) && Number.isFinite(value.expiresAt) &&
        value.chosenAt <= Date.now() && value.expiresAt > Date.now() &&
        value.expiresAt > value.chosenAt && value.expiresAt - value.chosenAt <= LIFETIME ? value : null;
    } catch { return null; }
  }
  function choice() {
    if (memory && valid(JSON.stringify(memory))) return memory;
    memory = valid(storage.get(KEY));
    if (!memory) { storage.remove(KEY); storage.remove(THEME); }
    return memory;
  }
  function getTheme() {
    const consent = choice();
    if (!consent?.appearance) { storage.remove(THEME); return null; }
    try {
      const value = JSON.parse(storage.get(THEME));
      if (value && ['light', 'dark'].includes(value.value) && value.expiresAt === consent.expiresAt) return value.value;
      storage.remove(THEME); return null;
    } catch { storage.remove(THEME); return null; }
  }
  function rememberTheme(theme) {
    const consent = choice();
    if (!consent?.appearance || !['light', 'dark'].includes(theme)) { storage.remove(THEME); return; }
    storage.set(THEME, JSON.stringify({value: theme, expiresAt: consent.expiresAt}));
  }
  function notify() { window.dispatchEvent(new CustomEvent('openweb:privacychange', {detail: {appearance: !!choice()?.appearance}})); }
  function save(appearance) {
    const chosenAt = Date.now();
    memory = {version: VERSION, appearance: !!appearance, chosenAt, expiresAt: chosenAt + LIFETIME};
    storage.set(KEY, JSON.stringify(memory));
    if (appearance && ['light', 'dark'].includes(document.documentElement.dataset.theme)) rememberTheme(document.documentElement.dataset.theme);
    else storage.remove(THEME);
    banner.hidden = true;
    if (dialog.open) dialog.close();
    notify();
  }
  function element(tag, text, className) {
    const value = document.createElement(tag);
    if (text) value.textContent = text;
    if (className) value.className = className;
    return value;
  }
  function button(text, action) {
    const value = element('button', text, 'privacy-button');
    value.type = 'button'; value.addEventListener('click', action); return value;
  }
  function link(text, href) { const value = element('a', text); value.href = href; return value; }
  function open() {
    priorFocus = document.activeElement;
    dialog.querySelector('#privacy-appearance').checked = !!choice()?.appearance;
    if (!dialog.open) dialog.showModal();
  }
  function ready() {
    banner = element('section', '', 'privacy-banner');
    banner.id = 'privacy-banner'; banner.setAttribute('aria-labelledby', 'privacy-banner-title');
    const heading = element('h2', 'Your privacy choices'); heading.id = 'privacy-banner-title';
    banner.append(heading, element('p', 'We use no advertising or analytics trackers. Optional storage remembers your colour theme. Your choice is saved for 180 days; the site works if you reject optional storage.'));
    const actions = element('div', '', 'privacy-actions');
    actions.append(button('Reject optional', () => save(false)), button('Accept optional', () => save(true)), button('Choose settings', open));
    banner.append(actions, link('Cookies and local storage', '/cookies')); banner.hidden = !!choice(); document.body.append(banner);

    dialog = element('dialog', '', 'privacy-dialog'); dialog.id = 'privacy-dialog'; dialog.setAttribute('aria-labelledby', 'privacy-dialog-title');
    const title = element('h2', 'Privacy choices'); title.id = 'privacy-dialog-title';
    const close = button('Close', () => dialog.close()); close.classList.add('privacy-close');
    const info = element('p', 'Essential storage remembers this privacy choice for 180 days. We use no analytics or advertising storage. You can change your choice here at any time.');
    const label = element('label', '', 'privacy-option'); const check = element('input'); check.type = 'checkbox'; check.id = 'privacy-appearance';
    label.append(check, element('span', 'Remember my colour theme (optional)'));
    const details = element('p', 'When allowed, your light/dark preference is saved on this browser until the privacy choice expires. Rejecting or withdrawing removes that saved preference. Changing theme still works on the current page without saving it.');
    const controls = element('div', '', 'privacy-actions');
    controls.append(button('Reject optional', () => save(false)), button('Accept optional', () => save(true)), button('Save my choices', () => save(check.checked)));
    dialog.append(close, title, info, label, details, controls, link('Read the cookie policy', '/cookies'));
    dialog.addEventListener('close', () => { if (priorFocus?.isConnected) priorFocus.focus(); }); document.body.append(dialog);
    document.querySelectorAll('[data-privacy-settings]').forEach(node => node.addEventListener('click', open));
    window.addEventListener('storage', event => {
      if (event.key !== KEY && event.key !== null) return;
      memory = null; const current = choice();
      if (!current?.appearance) storage.remove(THEME);
      banner.hidden = !!current;
      if (dialog.open) dialog.querySelector('#privacy-appearance').checked = !!current?.appearance;
      notify();
    });
    window.addEventListener('pageshow', () => { memory = null; const current = choice(); if (!current?.appearance) storage.remove(THEME); banner.hidden = !!current; });
  }
  window.OpenWebPrivacy = Object.freeze({getTheme, rememberTheme, open, hasAppearanceConsent: () => !!choice()?.appearance});
  if (!choice()?.appearance) storage.remove(THEME);
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, {once: true}); else ready();
})();
