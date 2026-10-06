(() => {
  'use strict';
  const method = document.getElementById('smtp-authentication');
  const credentials = document.getElementById('smtp-credentials');
  const hint = document.getElementById('ip-authentication-hint');
  const update = () => {
    const byIp = method.value === 'ip';
    credentials.hidden = byIp;
    hint.hidden = !byIp;
    credentials.querySelectorAll('input').forEach(input => {
      input.disabled = byIp;
      input.required = !byIp && (input.type !== 'password' || input.dataset.passwordStored !== 'true');
    });
  };
  method.addEventListener('change', update);
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
