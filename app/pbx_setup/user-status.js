(() => {
    'use strict';
    const table = document.querySelector('[data-phone-presence]');
    if (!table) return;
    const badges = [...table.querySelectorAll('[data-phone-number]')];
    const profiles = [...table.querySelectorAll('[data-call-status-number]')];
    const labels = {online: 'Online', offline: 'Offline', unavailable: 'Status unavailable'};
    const mark = (badge, state) => {
        if (!Object.hasOwn(labels, state)) state = 'unavailable';
        badge.classList.remove('online', 'offline', 'unavailable');
        badge.classList.add(state);
        if (badge.textContent !== labels[state]) badge.textContent = labels[state];
    };
    let timer;
    let stopped = false;
    const update = async () => {
        if (stopped) return;
        if (document.hidden) { timer = setTimeout(update, 5000); return; }
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 6000);
        try {
            const response = await fetch('/app/pbx_setup/user_status.php', {credentials: 'same-origin', cache: 'no-store', signal: controller.signal, headers: {Accept: 'application/json'}});
            if (!response.ok) throw new Error('status unavailable');
            const value = await response.json();
            if (value.domain_uuid !== table.dataset.phonePresence || !value.users || typeof value.users !== 'object' || Array.isArray(value.users)) throw new Error('PBX changed');
            for (const badge of badges) mark(badge, value.users[badge.dataset.phoneNumber]?.state);
            for (const profile of profiles) {
                const status = value.users[profile.dataset.callStatusNumber]?.call_status;
                profile.textContent = typeof status === 'string' && status.length <= 80 ? status : 'Status unavailable';
            }
        } catch (_) {
            for (const badge of badges) mark(badge, 'unavailable');
            for (const profile of profiles) profile.textContent = 'Status unavailable';
        } finally {
            clearTimeout(timeout);
            if (!stopped) timer = setTimeout(update, 5000);
        }
    };
    window.addEventListener('pagehide', () => { stopped = true; clearTimeout(timer); });
    timer = setTimeout(update, 5000);
})();
