(() => {
  'use strict';
  document.querySelectorAll('[data-panel]').forEach(panel => { panel.hidden = panel.dataset.panel !== 'general'; });
  document.querySelectorAll('[data-tab]').forEach(button => button.addEventListener('click', () => {
    const form = button.closest('form');
    form.querySelectorAll('[data-panel]').forEach(panel => { panel.hidden = panel.dataset.panel !== button.dataset.tab; });
    form.querySelectorAll('[data-tab]').forEach(tab => { tab.classList.toggle('selected', tab === button); tab.setAttribute('aria-selected', String(tab === button)); });
  }));
  document.querySelectorAll('[data-destination]').forEach(select => {
    const update = () => { const field = select.closest('label').nextElementSibling; if (field?.dataset.external !== undefined) field.hidden = select.value !== 'External:'; };
    select.addEventListener('change', update); update();
  });
  document.querySelectorAll('[data-search]').forEach(input => input.addEventListener('input', () => {
    const term = input.value.toLocaleLowerCase();
    document.querySelectorAll('[data-search-row]').forEach(row => { row.hidden = !row.textContent.toLocaleLowerCase().includes(term); });
  }));
  document.querySelectorAll('[data-authentication]').forEach(select => {
    const update = () => select.closest('form').querySelectorAll('[data-password-auth]').forEach(field => { field.hidden = select.value !== 'password'; });
    select.addEventListener('change', update); update();
  });
})();
