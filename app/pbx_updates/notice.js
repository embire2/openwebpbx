(() => {
    'use strict';
    const banner = document.getElementById('windows-server-update');
    if (!banner || window.top !== window.self) return;
    document.body.prepend(banner);
    const message = banner.querySelector('[data-server-update-message]');
    const detail = banner.querySelector('[data-server-update-detail]');
    const form = banner.querySelector('form');
    const button = banner.querySelector('button');
    let installing = false;
    const resize = () => document.documentElement.style.setProperty('--server-update-height', `${banner.getBoundingClientRect().height}px`);
    new ResizeObserver(resize).observe(banner);
    if (form) form.addEventListener('submit', event => {
        if (installing || !window.confirm('Install the downloaded update when active calls finish? The server will restart automatically.')) { event.preventDefault(); return; }
        installing = true;
        // Keep the submit button enabled until the browser serialises its action=install value.
        detail.textContent = 'Requesting installation. Calls will finish before the server restarts.';
    });
    async function refresh() {
        try {
            const response = await fetch('/app/pbx_updates/notice.php', {credentials:'same-origin', cache:'no-store', signal:AbortSignal.timeout(8000)});
            if (!response.ok) throw new Error('Status unavailable');
            const status = await response.json();
            if (typeof status.required !== 'boolean') throw new Error('Invalid status');
            banner.hidden = !status.required;
            document.documentElement.classList.toggle('has-server-update', status.required);
            if (status.required) {
                message.textContent = status.message;
                if (form) form.hidden = !status.can_install;
                if (button) button.disabled = !status.ready || installing;
                detail.textContent = !status.can_install ? 'Ask your instance administrator to install this update.' : status.ready ? 'Downloaded and verified. Your PBX remains available until installation starts.' : 'Preparing the download. Your PBX remains available.';
                resize();
            }
        } catch (_) {
            // Keep an already displayed requirement during network outages or the restart.
            if (!banner.hidden) detail.textContent = 'Reconnecting. You can also manage this update on the Windows server.';
        } finally { window.setTimeout(refresh, 10000); }
    }
    refresh();
})();
