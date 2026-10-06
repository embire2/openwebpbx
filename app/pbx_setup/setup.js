(() => {
    'use strict';
    const wizard = document.querySelector('[data-setup-wizard]');
    if (!wizard) return;
    const steps = Array.from(wizard.querySelectorAll('[data-setup-step]'));
    const progress = Array.from(document.querySelectorAll('[data-step-indicator]'));
    const previous = wizard.querySelector('[data-previous]');
    const next = wizard.querySelector('[data-next]');
    const review = wizard.querySelector('[data-review]');
    const users = wizard.querySelector('[data-user-rows]');
    const extraUsers = wizard.querySelector('[data-extra-users]');
    const add = wizard.querySelector('[data-add-user]');
    let current = 0;
    let rowId = users.querySelectorAll('[data-user-row]').length;
    const firstNumber = 100;
    const announce = wizard.querySelector('[data-step-announcement]');
    const move = (index, focus = true) => {
        current = Math.max(0, Math.min(index, steps.length - 1));
        steps.forEach((step, i) => { step.hidden = i !== current; });
        progress.forEach((item, i) => {
            item.classList.toggle('active', i === current);
            item.classList.toggle('complete', i < current);
            item.setAttribute('aria-current', i === current ? 'step' : 'false');
        });
        previous.hidden = current === 0;
        next.hidden = current === steps.length - 1;
        review.hidden = current !== steps.length - 1;
        announce.textContent = `Step ${current + 1} of ${steps.length + 1}: ${steps[current].dataset.title}`;
        if (focus) {
            const heading = steps[current].querySelector('h2');
            heading?.focus({preventScroll:true});
            steps[current].scrollIntoView({behavior:'smooth',block:'nearest'});
        }
    };
    const changed = () => wizard.dispatchEvent(new Event('change', {bubbles:true}));
    const updateUsers = () => {
        const choices = Array.from(users.querySelectorAll('[data-user-row]')).map(row => {
            const number = row.querySelector('[data-user-number]').value.trim();
            const name = row.querySelector('[data-user-name]').value.trim();
            row.querySelector('[data-user-name]').required = number !== '';
            return {number, name};
        }).filter(row => row.number);
        const destination = wizard.querySelector('[name=inbound_destination]');
        const old = destination.value;
        destination.replaceChildren(new Option('Choose who answers', ''));
        choices.forEach(row => destination.add(new Option(`${row.number}${row.name ? ' · ' + row.name : ''}`, row.number)));
        if (choices.some(row => row.number === old)) destination.value = old;
        else if (choices.length === 1) destination.value = choices[0].number;
    };
    if (extraUsers) {
        Array.from(extraUsers.querySelectorAll('[data-user-row]')).forEach(row => {
            const filled = Array.from(row.querySelectorAll('input')).some(input => input.value.trim());
            if (filled) users.insertBefore(row, extraUsers); else row.remove();
        });
        extraUsers.remove();
    }
    const addUser = () => {
        if (users.querySelectorAll('[data-user-row]').length >= 100) return;
        const fragment = document.querySelector('#setup-user-template').content.cloneNode(true);
        const row = fragment.querySelector('[data-user-row]');
        row.querySelectorAll('[name]').forEach(input => { input.name = input.name.replace('__ROW__', String(rowId)); });
        const used = Array.from(users.querySelectorAll('[data-user-number]')).map(input => Number(input.value)).filter(Number.isFinite);
        row.querySelector('[data-user-number]').value = String(Math.max(firstNumber - 1, ...used) + 1);
        rowId += 1;
        users.append(fragment);
        row.querySelector('[data-user-name]').focus();
        updateUsers();
        changed();
    };
    users.addEventListener('click', event => {
        const remove = event.target.closest('[data-remove-user]');
        if (!remove) return;
        const row = remove.closest('[data-user-row]');
        if (users.querySelectorAll('[data-user-row]').length > 1) { row.remove(); updateUsers(); changed(); }
    });
    users.addEventListener('input', updateUsers);
    add.hidden = false;
    add.addEventListener('click', addUser);
    const trunkHost = wizard.querySelector('[name="trunk[host]"]');
    const authentication = wizard.querySelector('[name="trunk[authentication]"]');
    const credentials = wizard.querySelector('[data-trunk-credentials]');
    const updateTrunk = () => {
        const enabled = trunkHost.value.trim() !== '';
        const password = authentication.value === 'password';
        credentials.hidden = !password;
        credentials.querySelectorAll('input').forEach(input => {
            input.disabled = !password;
            input.required = enabled && password;
        });
        wizard.querySelector('[data-ip-hint]').hidden = password;
        const inbound = wizard.querySelector('[name=inbound_number]');
        const destination = wizard.querySelector('[name=inbound_destination]');
        destination.required = inbound.value.trim() !== '';
    };
    authentication.addEventListener('change', updateTrunk);
    trunkHost.addEventListener('input', updateTrunk);
    wizard.querySelector('[name=inbound_number]').addEventListener('input', updateTrunk);
    const validStep = () => {
        updateUsers(); updateTrunk();
        const controls = Array.from(steps[current].querySelectorAll('input,select,textarea')).filter(input => !input.disabled);
        for (const control of controls) { if (!control.checkValidity()) { control.reportValidity(); return false; } }
        if (current === 1 && !users.querySelector('[data-user-number]').value.trim()) {
            users.querySelector('[data-user-number]').setCustomValidity('Add at least one user.');
            users.querySelector('[data-user-number]').reportValidity();
            users.querySelector('[data-user-number]').setCustomValidity('');
            return false;
        }
        return true;
    };
    previous.addEventListener('click', () => move(current - 1));
    next.addEventListener('click', () => { if (validStep()) move(current + 1); });
    wizard.addEventListener('submit', event => {
        // Reveal the section containing any invalid field so browser validation stays usable.
        updateUsers(); updateTrunk();
        for (let i = 0; i < steps.length; i++) {
            const invalid = Array.from(steps[i].querySelectorAll('input,select,textarea')).find(control => !control.disabled && !control.checkValidity());
            if (invalid) { event.preventDefault(); move(i); invalid.reportValidity(); return; }
        }
        review.disabled = true;
        review.textContent = 'Preparing review…';
    });
    wizard.noValidate = true;
    previous.hidden = true; next.hidden = false;
    updateUsers(); updateTrunk(); move(0, false);
})();
