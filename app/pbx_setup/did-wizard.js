(() => {
  'use strict';
  document.querySelectorAll('[data-did-wizard]').forEach(form => {
    const steps = [...form.querySelectorAll('[data-did-step]')];
    const field = name => form.elements.namedItem(name);
    const destination = field('destination');
    const hours = field('hours_mode');
    const external = form.querySelector('[data-did-external]');
    const outsideExternal = form.querySelector('[data-did-outside-external]');
    const office = form.querySelector('[data-did-office]');
    const schedule = form.querySelector('[data-did-schedule]');
    const review = form.querySelector('[data-did-review]');
    let step = 0;
    const selected = name => field(name)?.selectedOptions?.[0]?.textContent.trim() || '';
    const group = (element, visible) => {
      element.hidden = !visible;
      element.querySelectorAll('input,select').forEach(input => { input.disabled = !visible; });
    };
    const update = () => {
      const callback = destination.value.startsWith('CallMeBack:');
      const setupCallback = destination.value === 'CallMeBack:setup';
      group(external, destination.value === 'External:');
      field('external').required = destination.value === 'External:';
      schedule.hidden = callback;
      form.querySelector('[data-did-callback]').hidden = !callback || setupCallback;
      form.querySelector('[data-did-callback-setup]').hidden = !setupCallback;
      const newCallbackSetup = setupCallback && form.dataset.newDid === 'true';
      if (newCallbackSetup) field('enabled').checked = false;
      field('enabled').disabled = newCallbackSetup;
      group(office, !callback && hours.value === 'office');
      group(outsideExternal, !callback && hours.value === 'office' && field('outside').value === 'External:');
      field('outside_external').required = !callback && hours.value === 'office' && field('outside').value === 'External:';
      const lines = [
        ['Number', field('number').value.trim() || 'Otherwise unassigned numbers'],
        ['Provider', selected('trunk_id')],
        ['Number format', selected('number_country')],
        ['Destination', setupCallback ? 'Set up Call Me Back next; existing destination stays until ready' : destination.value === 'External:' ? `External number · ${field('external').value.trim()}` : selected('destination')],
        ['Schedule', setupCallback ? 'Existing routing retained during setup' : callback ? 'Call Me Back · all day' : hours.value === 'office' ? `Office hours · ${selected('office_department')}` : 'All day'],
        ['Incoming calls', field('enabled').checked ? 'Enabled' : 'Off']
      ];
      if (!callback && hours.value === 'office') lines.push(['When closed', field('outside').value === 'External:' ? `External number · ${field('outside_external').value.trim()}` : selected('outside')]);
      if (form.querySelector('[data-did-holiday]')) lines.push(['Holidays', callback ? 'Saved for normal routing' : 'Existing holiday routing is retained']);
      const list = document.createElement('dl');
      lines.forEach(([label, value]) => {
        const row = document.createElement('div');
        const title = document.createElement('dt');
        const text = document.createElement('dd');
        title.textContent = label; text.textContent = value;
        row.append(title, text); list.append(row);
      });
      review.replaceChildren(list);
    };
    const valid = index => {
      const invalid = [...steps[index].querySelectorAll('input,select')].find(input => !input.disabled && !input.checkValidity());
      if (!invalid) return true;
      invalid.reportValidity(); invalid.focus(); return false;
    };
    const show = (index, focus = true) => {
      step = index;
      steps.forEach((panel, i) => { panel.hidden = i !== step; });
      form.querySelectorAll('[data-did-progress]').forEach((item, i) => {
        item.classList.toggle('is-current', i === step);
        if (i === step) item.setAttribute('aria-current', 'step'); else item.removeAttribute('aria-current');
      });
      update();
      if (focus) steps[step].querySelector('h3').focus();
    };
    form.querySelectorAll('[data-did-navigation],[data-did-back]').forEach(button => { button.hidden = false; });
    form.querySelectorAll('[data-did-next]').forEach(button => button.addEventListener('click', () => { update(); if (valid(step)) show(step + 1); }));
    form.querySelectorAll('[data-did-back]').forEach(button => button.addEventListener('click', () => show(Math.max(0, step - 1))));
    form.addEventListener('input', update);
    form.addEventListener('change', update);
    // Validate the visible step ourselves so browser validation can focus errors.
    form.noValidate = true;
    form.addEventListener('submit', event => {
      update();
      for (let i = 0; i < 2; i++) {
        if ([...steps[i].querySelectorAll('input,select')].some(input => !input.disabled && !input.checkValidity())) {
          event.preventDefault(); show(i); valid(i); return;
        }
      }
      if (step < 2) { event.preventDefault(); show(step + 1); }
    });
    show(0, false);
  });
})();
