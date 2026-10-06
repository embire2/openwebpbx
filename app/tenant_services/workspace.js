(() => {
  'use strict';
  const $ = (s) => document.querySelector(s);
  $('[data-copy-invite]')?.addEventListener('click', async (event) => {
    const input = $('.invite-message input');
    try { await navigator.clipboard.writeText(input.value); event.currentTarget.textContent = 'Copied'; }
    catch { input.focus(); input.select(); }
  });
  const editor = $('#template-editor-data');
  if (editor) {
    const data = JSON.parse(editor.textContent);
    const counters = { trunks: 0, rules: 0, settings: 0 };
    const categories = ['dialplan','voicemail','email','smtp','timezone','limit','recordings','call_recording','ivr','ring_group','ring_groups','call_center','conference','fax','extension','extensions','device','devices','provision','cdr','xml_cdr','contacts','sip','number_translation'];
    const input = (label, name, value = '', options = {}) => {
      const wrapper = document.createElement('label'); wrapper.textContent = label;
      const field = document.createElement(options.values ? 'select' : 'input'); field.name = name;
      if (options.values) options.values.forEach((v) => { const o = document.createElement('option'); o.value = v; o.textContent = v; field.append(o); });
      else { field.type = options.type || 'text'; field.maxLength = options.maxLength || 200; }
      if (field.type === 'checkbox') { wrapper.className = 'check-label'; field.checked = Boolean(value); field.value = 'true'; }
      else { field.value = value; if (options.required) field.required = true; if (options.placeholder) field.placeholder = options.placeholder; }
      wrapper.append(field); return wrapper;
    };
    function refreshTrunks() {
      const rows = [...$('#trunks-rows').children];
      $('#rules-rows').querySelectorAll('select[data-trunk]').forEach((select) => {
        const selected = select.value; select.replaceChildren();
        const blank = document.createElement('option'); blank.value = ''; blank.textContent = 'Choose a trunk'; select.append(blank);
        rows.forEach((row, i) => { const option = document.createElement('option'); option.value = row.dataset.key; option.textContent = row.querySelector('[data-trunk-name]').value || `Trunk ${i + 1}`; select.append(option); });
        select.value = [...select.options].some((o) => o.value === selected) ? selected : '';
      });
    }
    function add(kind, values = {}) {
      const index = counters[kind]++; const base = `config[${kind}][${index}]`;
      const row = document.createElement('div'); row.className = 'editor-row'; row.dataset.kind = kind; row.dataset.key = index;
      const h = document.createElement('h3'); h.textContent = kind === 'trunks' ? 'SIP trunk' : kind === 'rules' ? 'Calling rule' : 'Domain setting'; row.append(h);
      const remove = document.createElement('button'); remove.type = 'button'; remove.className = 'remove-row'; remove.textContent = '×'; remove.setAttribute('aria-label', `Remove ${h.textContent.toLowerCase()}`);
      remove.addEventListener('click', () => { row.remove(); refreshTrunks(); $('#template-form').dispatchEvent(new Event('change', { bubbles: true })); }); row.append(remove);
      const grid = document.createElement('div'); grid.className = 'form-grid'; row.append(grid);
      if (kind === 'trunks') {
        const name = input('Trunk name', `${base}[name]`, values.name || '', { required: true, maxLength: 60 }); name.querySelector('input').dataset.trunkName = 'true'; name.addEventListener('input', refreshTrunks); grid.append(name);
        grid.append(input('SIP proxy', `${base}[proxy]`, values.proxy || '', { required: true, placeholder: 'sip.provider.example' }), input('Username', `${base}[username]`, values.username || ''), input('Password', `${base}[password]`, '', { type: 'password', maxLength: 256, placeholder: values.has_password ? 'Stored — leave blank to keep' : 'Optional default credential' }), input('Transport', `${base}[transport]`, values.transport || 'udp', { values: ['udp','tcp','tls'] }), input('Register with provider', `${base}[register]`, values.register ?? true, { type: 'checkbox' }), input('Enable on new services', `${base}[enabled]`, values.enabled ?? false, { type: 'checkbox' }));
      } else if (kind === 'rules') {
        grid.append(input('Rule name', `${base}[name]`, values.name || '', { required: true, maxLength: 60 }), input('Destination number pattern', `${base}[pattern]`, values.pattern || '^(0[0-9]{9})$', { required: true, maxLength: 180 }));
        const trunk = input('Route through trunk', `${base}[trunk]`, '', { values: [] }); const select = trunk.querySelector('select'); select.dataset.trunk = 'true'; select.required = true; grid.append(trunk, input('Prefix to add to the number', `${base}[prefix]`, values.prefix || '', { maxLength: 10 })); row.dataset.initialTrunk = values.trunk ?? '';
      } else {
        grid.append(input('Category', `${base}[category]`, values.category || 'voicemail', { values: categories }), input('Setting name', `${base}[subcategory]`, values.subcategory || '', { required: true, maxLength: 80 }), input('Value type', `${base}[type]`, values.type || 'text', { values: ['text','numeric','boolean','array'] }));
        const secret = values.has_secret || /password|secret|token/i.test(values.subcategory || '');
        const value = input('Value', `${base}[value]`, values.value || '', { type: secret ? 'password' : 'text', maxLength: 4096, placeholder: values.has_secret ? 'Stored — leave blank to keep' : '' }); grid.append(value);
        grid.querySelector('[name$="[subcategory]"]').addEventListener('input', (event) => { value.querySelector('input').type = /password|secret|token/i.test(event.target.value) ? 'password' : 'text'; });
      }
      $(`#${kind}-rows`).append(row); refreshTrunks(); if (kind === 'rules') row.querySelector('select').value = row.dataset.initialTrunk;
    }
    ['trunks','rules','settings'].forEach((kind) => (data[kind] || []).forEach((value) => add(kind, value)));
    document.querySelectorAll('[data-add]').forEach((button) => button.addEventListener('click', () => { add(button.dataset.add); button.dispatchEvent(new Event('change', { bubbles: true })); }));
    $('#template-form').addEventListener('submit', () => {
      // Number rows densely after deletions so trunk references remain deterministic.
      const trunkMap = new Map([...$('#trunks-rows').children].map((row, i) => [row.dataset.key, i]));
      $('#rules-rows').querySelectorAll('select[data-trunk]').forEach((select) => { const selected = select.selectedOptions[0]; if (selected && trunkMap.has(selected.value)) selected.value = trunkMap.get(selected.value); });
      ['trunks','rules','settings'].forEach((kind) => [...$(`#${kind}-rows`).children].forEach((row, i) => row.querySelectorAll('[name]').forEach((field) => { field.name = field.name.replace(/\[\d+\]/, `[${i}]`); })));
    });
  }
  const presets = $('#service-template-data');
  if (presets) {
    const templates = JSON.parse(presets.textContent);
    $('#service-template')?.addEventListener('change', (event) => {
      const template = templates[event.target.value]; const preview = $('#service-preview'); const credentials = $('#service-credentials'); preview.replaceChildren(); credentials.replaceChildren();
      if (!template) return;
      const name = document.createElement('strong'); name.textContent = template.name; const description = document.createElement('p'); description.textContent = template.description;
      const details = document.createElement('span'); details.textContent = `${template.extensions} extensions · ${template.timezone} · ${template.trunks.length} SIP trunks`; preview.append(name, description, details);
      template.trunks.forEach((trunk, i) => ['username','password'].forEach((field) => { const label = document.createElement('label'); label.textContent = `${trunk.name} — ${field}`; const input = document.createElement('input'); input.type = field === 'password' ? 'password' : 'text'; input.name = `credentials[${i}][${field}]`; input.autocomplete = 'off'; input.placeholder = trunk[`has_${field}`] ? 'Leave blank to use template default' : `Enter your SIP ${field}`; input.maxLength = field === 'password' ? 256 : 200; label.append(input); credentials.append(label); }));
    });
  }
})();
