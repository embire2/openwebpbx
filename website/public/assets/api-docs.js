'use strict';

// Static documentation only: no credentials, API requests or tracking.
(() => {
  const root = document.documentElement;
  const themeButton = document.querySelector('[data-api-theme]');
  if (themeButton) themeButton.hidden = false;
  function theme(value, remember = false) {
    root.dataset.theme = value === 'dark' ? 'dark' : 'light';
    const dark = root.dataset.theme === 'dark';
    if (themeButton) {
      themeButton.textContent = dark ? 'Light appearance' : 'Dark appearance';
      themeButton.setAttribute('aria-label', dark ? 'Switch to light appearance' : 'Switch to dark appearance');
    }
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.content = dark ? '#172e46' : '#dceafa';
    if (remember) window.OpenWebPrivacy?.rememberTheme(root.dataset.theme);
  }
  theme(window.OpenWebPrivacy?.getTheme() || (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));
  themeButton?.addEventListener('click', () => theme(root.dataset.theme === 'dark' ? 'light' : 'dark', true));
  window.addEventListener('openweb:privacychange', () => {
    const remembered = window.OpenWebPrivacy?.getTheme();
    if (remembered) theme(remembered);
  });

  const filter = document.querySelector('[data-api-filter]');
  const input = document.querySelector('#api-filter');
  const count = document.querySelector('[data-api-count]');
  const empty = document.querySelector('[data-api-empty]');
  const endpoints = [...document.querySelectorAll('[data-api-endpoint]')];
  if (filter && input && count && empty) {
    filter.hidden = false;
    input.addEventListener('input', () => {
      const words = input.value.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
      let matches = 0;
      for (const endpoint of endpoints) {
        const text = endpoint.textContent.toLocaleLowerCase();
        endpoint.hidden = !words.every(word => text.includes(word));
        if (!endpoint.hidden) matches++;
      }
      count.textContent = `${matches} of ${endpoints.length} endpoints shown.`;
      empty.hidden = matches !== 0;
    });
  }

  const feedback = document.querySelector('[data-api-feedback]');
  let timer;
  function inform(message) {
    if (!feedback) return;
    feedback.textContent = message;
    feedback.hidden = false;
    clearTimeout(timer);
    timer = setTimeout(() => { feedback.hidden = true; }, 3500);
  }
  for (const button of document.querySelectorAll('[data-copy-code]')) {
    const code = document.getElementById(button.dataset.copyCode);
    if (!code) continue;
    button.hidden = false;
    button.addEventListener('click', async () => {
      try {
        if (!window.isSecureContext || !navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
        await navigator.clipboard.writeText(code.textContent);
        inform('Example copied. Replace the sample values before using it.');
      } catch {
        const range = document.createRange();
        range.selectNodeContents(code);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        inform('Example selected. Use your device’s Copy command.');
      }
    });
  }
})();
