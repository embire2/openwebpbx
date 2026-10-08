(() => {
  'use strict';
  const whitelist = document.getElementById('smtp-ip-whitelisted');
  const credentials = document.getElementById('smtp-credentials');
  const update = () => {
    const byIp = whitelist.checked;
    credentials.hidden = byIp;
    credentials.querySelectorAll('input').forEach(input => {
      input.disabled = byIp;
      input.required = !byIp && (input.type !== 'password' || input.dataset.passwordStored !== 'true');
    });
  };
  whitelist.addEventListener('change', update);
  update();
  document.getElementById('copy-source-ip').addEventListener('click', async event => {
    const button = event.currentTarget;
    try {
      await navigator.clipboard.writeText(document.getElementById('smtp-source-ip').textContent.trim());
      button.textContent = 'Copied';
      setTimeout(() => { button.textContent = 'Copy IP'; }, 2000);
    } catch {
      const range = document.createRange();
      range.selectNodeContents(document.getElementById('smtp-source-ip'));
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      button.textContent = 'Select and copy';
    }
  });
})();
