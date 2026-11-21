/* OpenWeb PBX: progress stays visible while the independent updater restarts the PBX. */
(() => {
    'use strict';
    const panel = document.querySelector('[data-update-status]');
    if (!panel) return;
    const message = panel.querySelector('[data-update-message]');
    const version = panel.querySelector('[data-update-version]');
    const available = panel.querySelector('[data-update-available]');
    const progress = panel.querySelector('progress');
    const offline = panel.querySelector('[data-update-offline]');
    const verified = panel.querySelector('[data-update-verified]');
    const reported = panel.querySelector('[data-update-reported]');
    const actions = panel.querySelectorAll('[data-update-action]');
    const initialVersion = panel.dataset.updateVersion;
    let failures = 0;
    let changed = false;
    document.querySelectorAll('form').forEach(form => form.addEventListener('change', () => { changed = true; }));

    const schedule = document.querySelector('[data-update-schedule]');
    const localTime = new Intl.DateTimeFormat(undefined, {dateStyle: 'medium', timeStyle: 'short'});
    function showReportedTime(value) {
        if (!reported) return;
        const time = new Date(value || '');
        reported.hidden = Number.isNaN(time.getTime());
        if (!reported.hidden) {
            const stamp = reported.querySelector('time');
            stamp.dateTime = value;
            stamp.textContent = localTime.format(time);
        }
    }
    showReportedTime(reported?.querySelector('time').dateTime);

    function showLocalWindow() {
        if (!schedule) return;
        const preview = schedule.querySelector('[data-update-local-window]');
        preview.hidden = true;
        if (schedule.querySelector('input[name="mode"]:checked')?.value !== 'automatic') return;
        const hour = Number(schedule.elements.maintenance_hour.value);
        const duration = Number(schedule.elements.maintenance_duration.value);
        if (!Number.isInteger(hour) || hour < 0 || hour > 23 || !Number.isInteger(duration) || duration < 1 || duration > 6) return;
        const now = new Date();
        const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), hour));
        if (start > now) start.setUTCDate(start.getUTCDate() - 1);
        const length = duration * 3600000;
        const opened = now.getTime() < start.getTime() + length;
        if (!opened) start.setUTCDate(start.getUTCDate() + 1);
        const end = new Date(start.getTime() + length);
        const zone = localTime.resolvedOptions().timeZone;
        preview.textContent = `${opened ? 'Current' : 'Next'} window in your browser time (${zone}): ${localTime.format(start)} to ${localTime.format(end)}.`;
        preview.hidden = false;
    }
    if (schedule) {
        schedule.addEventListener('change', showLocalWindow);
        showLocalWindow();
    }

    function disableActions() {
        actions.forEach(button => { button.disabled = true; });
    }

    async function refresh() {
        try {
            const response = await fetch('/app/pbx_updates/status.php', {credentials: 'same-origin', cache: 'no-store', signal: AbortSignal.timeout(8000)});
            if (response.status === 403 || response.redirected) {
                message.textContent = 'Sign in again to view update progress.';
                disableActions();
                return;
            }
            if (!response.ok || !response.headers.get('content-type')?.includes('application/json')) throw new Error('Unavailable');
            const state = await response.json();
            failures = 0;
            if (offline) offline.hidden = Boolean(state.service_online);
            message.textContent = typeof state.message === 'string' ? state.message : 'Checking update status…';
            version.textContent = state.installed_version || initialVersion;
            if (verified) {
                const controls = state.server_controls;
                if (!controls) throw new Error('Unavailable');
                available.textContent = controls.offered_version || (controls.up_to_date ? 'Up to date' : 'Awaiting a verified offer');
                verified.hidden = controls.download_verified !== true;
                actions.forEach(button => { button.disabled = controls[button.dataset.updateAction] !== true; });
                showReportedTime(state.checked_at);
                showLocalWindow();
            } else {
                available.textContent = state.available_version ? ` · Available: ${state.available_version}` : '';
            }
            const total = Number(state.total_bytes);
            const downloaded = Number(state.progress_bytes);
            progress.hidden = !((!verified || state.state === 'downloading') && total > 0 && downloaded >= 0 && downloaded < total);
            if (!progress.hidden) { progress.max = total; progress.value = downloaded; }
            if (!changed && state.service_online && initialVersion !== 'unknown' && state.installed_version && state.installed_version !== initialVersion) {
                // Navigate with GET: reloading a completed POST would replay its used CSRF token.
                window.location.replace(window.location.href);
                return;
            }
        } catch (_) {
            failures += 1;
            disableActions();
            message.textContent = failures > 3 ? 'Waiting for the server. This page will reconnect automatically.' : 'Reconnecting to the server…';
        }
        window.setTimeout(refresh, failures ? 10000 : 5000);
    }
    window.setTimeout(refresh, 5000);
})();
