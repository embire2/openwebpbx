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
    const initialVersion = panel.dataset.updateVersion;
    let failures = 0;
    let changed = false;
    document.querySelectorAll('form').forEach(form => form.addEventListener('change', () => { changed = true; }));
    async function refresh() {
        try {
            const response = await fetch('/app/pbx_updates/status.php', {credentials: 'same-origin', cache: 'no-store', signal: AbortSignal.timeout(8000)});
            if (response.status === 403 || response.redirected) {
                message.textContent = 'Sign in again to view update progress.';
                return;
            }
            if (!response.ok || !response.headers.get('content-type')?.includes('application/json')) throw new Error('Unavailable');
            const state = await response.json();
            failures = 0;
            if (offline) offline.hidden = Boolean(state.service_online);
            message.textContent = typeof state.message === 'string' ? state.message : 'Checking update status…';
            version.textContent = state.installed_version || initialVersion;
            available.textContent = state.available_version ? ` · Available: ${state.available_version}` : '';
            const total = Number(state.total_bytes);
            const downloaded = Number(state.progress_bytes);
            progress.hidden = !(total > 0 && downloaded >= 0 && downloaded < total);
            if (!progress.hidden) { progress.max = total; progress.value = downloaded; }
            if (!changed && state.service_online && initialVersion !== 'unknown' && state.installed_version && state.installed_version !== initialVersion) {
                // Navigate with GET: reloading a completed POST would replay its used CSRF token.
                window.location.replace(window.location.href);
                return;
            }
        } catch (_) {
            failures += 1;
            message.textContent = failures > 3 ? 'Waiting for the server. This page will reconnect automatically.' : 'Reconnecting to the server…';
        }
        window.setTimeout(refresh, failures ? 10000 : 5000);
    }
    window.setTimeout(refresh, 5000);
})();
