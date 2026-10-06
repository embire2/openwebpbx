(() => {
  'use strict';
  const embedded = window.self !== window.top;
  document.documentElement.classList.add(embedded ? 'openweb-embedded' : 'openweb-page');
  const notify = (action, values = {}) => {
    if (embedded) window.parent.postMessage({ type: 'openweb-app', action, ...values }, location.origin);
  };
  document.addEventListener('DOMContentLoaded', () => {
    if (!embedded) {
      const bar = document.createElement('div');
      bar.className = 'openweb-app-header';
      const home = document.createElement('a');
      home.href = '/core/desktop/';
      home.textContent = '‹  Desktop';
      const brand = document.createElement('strong');
      brand.textContent = 'OpenWeb PBX';
      bar.append(home, brand);
      document.body.prepend(bar);
    }
    const domain = document.body.dataset.openwebDomain;
    if (domain) notify('domain', { uuid: domain });
    const trackChange = (event) => {
      const form = event.target.closest('form');
      if (form && form.method.toLowerCase() === 'post' && !event.target.matches('input[type=search], input[name=search], input[name=search_all], input[id^=checkbox_]')) notify('dirty', { dirty: true });
    };
    document.addEventListener('input', trackChange);
    document.addEventListener('change', trackChange);
    document.addEventListener('submit', () => notify('dirty', { dirty: false }));
    document.addEventListener('click', (event) => {
      const anchor = event.target.closest('a');
      if (!anchor) return;
      const url = new URL(anchor.href, location.href);
      if (embedded && url.origin === location.origin && url.pathname === '/logout.php') {
        event.preventDefault(); notify('signout');
      }
      if (embedded && url.origin === location.origin && url.pathname.startsWith('/core/dashboard')) {
        url.searchParams.set('classic', '1'); anchor.href = url.href;
      }
    });
  });
})();
