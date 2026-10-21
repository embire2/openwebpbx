(() => {
  'use strict';
  document.querySelectorAll('[data-trunk-route]').forEach(select => {
    const form = select.form;
    const update = () => {
      const callback = select.value.startsWith('CallMeBack:');
      form.querySelector('[data-callback-info]').hidden = !callback;
      const normal = form.querySelector('[data-normal-routing]');
      normal.hidden = callback;
      normal.querySelectorAll('input, select').forEach(field => { field.disabled = callback; });
      select.closest('label').nextElementSibling.hidden = select.value !== 'External:';
    };
    select.addEventListener('change', update);
    update();
  });
})();
