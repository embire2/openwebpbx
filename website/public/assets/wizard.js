'use strict';

(() => {
  const API = 'https://call.openweb.co.za/api/v1/wizard';
  const panels = [...document.querySelectorAll('[data-panel]')];
  const errorBox = document.querySelector('[data-wizard-error]');
  const noticeBox = document.querySelector('[data-wizard-notice]');
  const stepNames = ['server', 'account', 'address', 'progress'];
  let bearer = '', registrationPassword = '', email = '', userCode = '', company = '';
  let pairing = '', mode = 'register', verifyExisting = false, termsAccepted = false;
  let busy = false, pollTimer = null, pollCount = 0;
  const fragment = new URLSearchParams(location.hash.slice(1));
  const resumeId = /^[a-f0-9-]{36}$/.test(fragment.get('setup') || '') ? fragment.get('setup') : '';
  const initialCode = fragment.get('code') || '';
  if (/^[a-fA-F0-9 -]{10,24}$/.test(initialCode)) document.querySelector('#server-code').value = initialCode;
  if (resumeId) pairing = resumeId;

  function clearMessage() { errorBox.hidden = true; noticeBox.hidden = true; }
  function showError(error) {
    errorBox.textContent = error?.message || 'We could not complete this step. Try again shortly.';
    errorBox.hidden = false; errorBox.scrollIntoView({block: 'nearest', behavior: 'smooth'});
  }
  function notice(message) { noticeBox.textContent = message; noticeBox.hidden = false; }
  function panel(name) {
    clearMessage(); panels.forEach(value => { value.hidden = value.dataset.panel !== name; });
    const progress = name === 'verify' ? 1 : name === 'ready' ? 4 : stepNames.indexOf(name);
    document.querySelectorAll('[data-step]').forEach((value, index) => {
      value.toggleAttribute('data-finished', index < progress);
      if (index === progress) value.setAttribute('aria-current', 'step'); else value.removeAttribute('aria-current');
    });
    document.querySelector(`[data-panel="${name}"] h2`)?.focus({preventScroll: true});
  }
  function setBusy(value) {
    busy = value;
    document.querySelectorAll('form button, [data-check-again]').forEach(button => { button.disabled = value; });
  }
  async function request(path, body, authenticated = false, method = 'POST') {
    const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 38000);
    const headers = {'Accept': 'application/json'};
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (authenticated) {
      if (!bearer) throw new Error('Sign in to your OpenWeb PBX account to continue.');
      headers.Authorization = 'Bearer ' + bearer;
    }
    try {
      const response = await fetch(API + path, {method, headers, body: body === undefined ? undefined : JSON.stringify(body),
        credentials: 'omit', redirect: 'error', cache: 'no-store', referrerPolicy: 'no-referrer', signal: controller.signal});
      const content = await response.text();
      if (content.length > 65536) throw new Error('The setup service returned an unexpected response. Try again shortly.');
      let data; try { data = JSON.parse(content); } catch { throw new Error('The setup service is temporarily unavailable. Try again shortly.'); }
      if (!response.ok) {
        const failure = new Error(data?.error?.message || 'This setup step is not available yet. Try again shortly.');
        failure.code = data?.error?.code; failure.status = response.status; throw failure;
      }
      return data;
    } catch (error) {
      if (error.name === 'AbortError' || error instanceof TypeError) throw new Error('We could not reach the setup service. Check your connection and try again.');
      throw error;
    } finally { clearTimeout(timer); }
  }
  function slug(value) {
    return value.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40).replace(/-+$/g, '');
  }
  function accountMode(value) {
    mode = value;
    document.querySelectorAll('[data-account-mode]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.accountMode === mode)));
    document.querySelectorAll('[data-registration-fields]').forEach(value => { value.hidden = mode !== 'register'; });
    document.querySelector('#company-name').required = mode === 'register'; document.querySelector('#account-terms').required = mode === 'register';
    const password = document.querySelector('#account-password'); password.minLength = mode === 'register' ? 12 : 1;
    password.autocomplete = mode === 'register' ? 'new-password' : 'current-password';
    document.querySelector('#password-help').textContent = mode === 'register' ? 'Use at least 12 characters, including a letter and a number.' : 'Use your existing OpenWeb PBX account password.';
    document.querySelector('[data-account-submit]').textContent = mode === 'register' ? 'Create my account →' : 'Sign in →';
  }
  function addressStep() {
    document.querySelector('#tenant-label').value ||= slug(company);
    document.querySelector('#address-terms').checked = termsAccepted; panel('address');
  }
  function emailStep(existing) {
    verifyExisting = existing;
    document.querySelectorAll('[data-email-label]').forEach(value => { value.textContent = email; });
    document.querySelector('#verification-code').value = '';
    const passwordNeeded = existing || !registrationPassword;
    document.querySelector('[data-verification-password]').hidden = !passwordNeeded;
    document.querySelector('#verification-password').required = passwordNeeded;
    panel('verify');
  }
  async function resume() {
    if (pairing) { panel('progress'); await poll(); }
    else addressStep();
  }
  document.querySelectorAll('[data-account-mode]').forEach(button => button.addEventListener('click', () => { if (!busy) accountMode(button.dataset.accountMode); }));
  document.querySelector('#server-form').addEventListener('submit', async event => {
    event.preventDefault(); if (busy || !event.currentTarget.reportValidity()) return; clearMessage(); setBusy(true);
    try {
      userCode = document.querySelector('#server-code').value.trim().toUpperCase();
      const server = await request('/devices/lookup', {user_code: userCode});
      const provider = server.provider === 'webhotel' ? 'Webhotel.cloud' : 'Self-installed';
      document.querySelector('[data-server-summary]').textContent = provider + ' server · ' + server.server_address + ' · OpenWeb PBX ' + server.image_version;
      panel('account');
    } catch (error) { showError(error); } finally { setBusy(false); }
  });
  document.querySelector('#account-form').addEventListener('submit', async event => {
    event.preventDefault(); if (busy || !event.currentTarget.reportValidity()) return; clearMessage(); setBusy(true);
    const password = document.querySelector('#account-password').value; email = document.querySelector('#account-email').value.trim();
    try {
      if (mode === 'register') {
        company = document.querySelector('#company-name').value.trim(); const shortName = slug(company);
        if (shortName.length < 3) throw new Error('Use a company name with at least three letters or numbers, or sign in to an existing account.');
        termsAccepted = document.querySelector('#account-terms').checked;
        await request('/account/register', {tenant_name: company, slug: shortName, email, password, accept_terms: termsAccepted});
        registrationPassword = password; document.querySelector('#account-password').value = ''; emailStep(false);
      } else {
        const data = await request('/account/login', {email, password}); bearer = data.access_token; company = data.tenant?.tenant_name || '';
        registrationPassword = ''; document.querySelector('#account-password').value = ''; await resume();
      }
    } catch (error) { showError(error); } finally { setBusy(false); }
  });
  document.querySelector('#verify-form').addEventListener('submit', async event => {
    event.preventDefault(); if (busy || !event.currentTarget.reportValidity()) return; clearMessage(); setBusy(true);
    try {
      const password = registrationPassword || document.querySelector('#verification-password').value;
      const body = {token: document.querySelector('#verification-code').value.trim(), password};
      if (verifyExisting) await request('/account/email/verify', body, true);
      else { const data = await request('/account/verify', body); bearer = data.access_token; company = data.tenant?.tenant_name || company; }
      registrationPassword = ''; document.querySelector('#verification-password').value = ''; document.querySelector('#verification-code').value = '';
      await resume();
    } catch (error) { showError(error); } finally { setBusy(false); }
  });
  document.querySelector('[data-restart-account]').addEventListener('click', () => {
    if (busy) return; registrationPassword = ''; document.querySelector('#verification-password').value = ''; panel('account');
  });
  document.querySelector('#address-form').addEventListener('submit', async event => {
    event.preventDefault(); if (busy || !event.currentTarget.reportValidity()) return; clearMessage(); setBusy(true);
    termsAccepted = document.querySelector('#address-terms').checked;
    try {
      const data = await request('/claim', {user_code: userCode, label: document.querySelector('#tenant-label').value,
        confirm_server: document.querySelector('#confirm-server').checked, accept_terms: termsAccepted}, true);
      pairing = data.pairing_uuid; history.replaceState(null, '', '#setup=' + pairing); panel('progress'); await poll();
    } catch (error) {
      if (error.code === 'verified_account_required') {
        try { await request('/account/email/request', {}, true); emailStep(true); } catch (failure) { showError(failure); }
      } else showError(error);
    } finally { setBusy(false); }
  });
  async function poll() {
    clearTimeout(pollTimer); if (!pairing || !bearer) return;
    try {
      const data = await request('/sessions/' + pairing, undefined, true, 'GET');
      const ordered = ['pending', 'claimed', 'bootstrap_pending', 'dns_ready', 'authorized', 'complete']; const stage = ordered.indexOf(data.state);
      document.querySelectorAll('[data-check]').forEach(node => node.toggleAttribute('data-complete', ordered.indexOf(node.dataset.check) <= stage));
      const messages = {pending: 'Your server is waiting to connect to this account.', claimed: 'Your account is connected. Your server is checking in.',
        bootstrap_pending: 'We are preparing the server address.', dns_ready: 'Your server address is created. The secure connection is being prepared.',
        authorized: 'Your server is authorized. We are checking its tenant address and secure connection.', complete: 'Your server is ready.'};
      document.querySelector('[data-progress-message]').textContent = messages[data.state] || 'Your server is still being prepared. Keep it running.';
      if (data.ready) {
        const url = new URL(data.tenant_url);
        if (url.protocol !== 'https:' || url.username || url.password || url.port || url.search || url.hash || url.pathname !== '/'
            || !/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\.openwebpbx\.com$/.test(url.hostname)) throw new Error('The setup address needs administrator review.');
        document.querySelector('[data-ready-address]').textContent = url.origin; document.querySelector('[data-open-admin]').href = url.origin + '/admin'; panel('ready');
        bearer = ''; registrationPassword = ''; return;
      }
      if (data.state === 'revoked') throw new Error('This server setup has been cancelled. Start a new setup from the server.');
      if (Date.parse(data.expires_at) <= Date.now() && !['authorized', 'complete'].includes(data.state)) throw new Error('This setup session expired. Reopen setup from your server to continue.');
      pollCount++; if (pollCount < 360) pollTimer = setTimeout(poll, 5000); else notice('Setup is taking longer than usual. Keep the server running and use Check progress now to retry.');
    } catch (error) {
      showError(error);
      if (error.status === 401) { bearer = ''; accountMode('login'); panel('account'); notice('Sign in again to check your server setup.'); }
      else if ((!error.status || error.status >= 500 || error.status === 429) && ++pollCount < 360) pollTimer = setTimeout(poll, 15000);
    }
  }
  document.querySelector('[data-check-again]').addEventListener('click', () => { if (!busy) { pollCount = 0; poll(); } });
  const themeButton = document.querySelector('[data-wizard-theme]'); themeButton.hidden = false;
  function theme(value, save = false) {
    document.documentElement.dataset.theme = value === 'dark' ? 'dark' : 'light';
    themeButton.textContent = value === 'dark' ? 'Light appearance' : 'Dark appearance';
    if (save) window.OpenWebPrivacy?.rememberTheme(document.documentElement.dataset.theme);
  }
  theme(window.OpenWebPrivacy?.getTheme() || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));
  themeButton.addEventListener('click', () => theme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark', true));
  window.addEventListener('pagehide', () => { clearTimeout(pollTimer); bearer = ''; registrationPassword = ''; document.querySelectorAll('input[type=password]').forEach(value => { value.value = ''; }); });
  window.addEventListener('pageshow', event => {
    if (event.persisted && !bearer && document.querySelector('[data-panel="server"]').hidden && document.querySelector('[data-panel="ready"]').hidden) {
      accountMode('login'); panel('account'); notice('Sign in again to continue your server setup.');
    }
  });
  if (resumeId) { accountMode('login'); panel('account'); notice('Sign in to reopen your server setup.'); }
})();
