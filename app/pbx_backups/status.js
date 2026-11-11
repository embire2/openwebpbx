(() => {
  'use strict';
  const root = document.querySelector('[data-backup-watch]');
  if (!root) return;
  const endpoint = new URL(location.href);
  endpoint.searchParams.set('format', 'status');
  const tenant = root.dataset.backupTenant || '';
  const labels = {create: 'Create backup', verify: 'Check backup', instance_create: 'Create full backup',
    instance_verify: 'Check full backup', instance_restore: 'Restore full backup', tenant_create: 'Create tenant backup',
    tenant_verify: 'Check tenant backup', tenant_restore: 'Restore tenant backup', tenant_import: 'Upload tenant backup',
    instance_import: 'Upload full backup'};
  const states = {pending: 'Waiting', running: 'Working', completed: 'Complete', failed: 'Failed', ready: 'Ready', creating: 'Creating'};
  const node = (tag, text, className) => {
    const item = document.createElement(tag);
    if (text !== undefined) item.textContent = text;
    if (className) item.className = className;
    return item;
  };
  const notice = node('p', 'Checking backup progress…', 'setup-hint');
  notice.setAttribute('role', 'status');
  root.querySelector('header')?.after(notice);
  let stopped = false;
  async function refresh() {
    try {
      if (document.hidden) return;
      const response = await fetch(endpoint, {credentials: 'same-origin', cache: 'no-store', headers: {'Accept': 'application/json'}});
      if (response.status === 401 || response.status === 403 || response.redirected ||
          (response.ok && !(response.headers.get('content-type') || '').includes('application/json'))) {
        stopped = true;
        notice.textContent = 'Sign in again to see current backup progress.';
        return;
      }
      if (!response.ok) throw new Error('unavailable');
      const data = await response.json();
      if (data.error || !data.status) throw new Error('unavailable');
      const status = data.status;
      const jobs = status.jobs || status.recent || [];
      const active = jobs.filter(job => ['pending', 'running'].includes(job.status));
      notice.textContent = active.length ? 'Request in progress. Results update automatically.'
        : 'Backup results are up to date.';
      const message = root.querySelector('[data-backup-message]');
      if (message && typeof status.message === 'string') message.textContent = status.message;
      const hint = root.querySelector('[data-backup-service-hint]');
      if (hint && typeof status.service_online === 'boolean') hint.hidden = status.service_online;
      const list = root.querySelector('[data-backup-list]');
      for (const backup of status.backups || []) {
        if (!list || !/^[a-f0-9-]{36}$/.test(backup.backup_uuid)) continue;
        let entry = list.querySelector(`[data-backup-id="${backup.backup_uuid}"]`);
        if (!entry) {
          entry = node('article', undefined, 'backup-entry');
          entry.dataset.backupId = backup.backup_uuid;
          entry.append(node('h3', backup.created_at), node('p', '', 'backup-live-meta'), node('p', '', 'backup-live-note'));
          list.prepend(entry);
        }
        entry.id = `backup-${backup.backup_uuid}`;
        const meta = entry.querySelector('.backup-live-meta');
        let note = entry.querySelector('.backup-live-note');
        if (!note) { note = node('p', '', 'backup-live-note'); entry.append(note); }
        const label = (backup.message || '').startsWith('Previous server:') ? 'Previous server' : (states[backup.status] || backup.status);
        const media = !('include_media' in backup) || [true, 'true', 't', 1].includes(backup.include_media) ? 'Settings and media' : 'Settings only';
        if (meta) meta.textContent = `${label} · ${backup.app_version} · ${media} · ${(Number(backup.size_bytes) / 1048576).toFixed(1)} MB`;
        note.textContent = backup.message || '';
        for (const button of entry.querySelectorAll('form button')) button.disabled = backup.status !== 'ready';
        const download = entry.querySelector('a[href*="download.php"]');
        if (backup.status !== 'ready') { download?.remove(); continue; }
        if (!download) {
          const link = node('a', 'Download encrypted copy', 'setup-button');
          link.href = tenant ? `/app/pbx_protection/download.php?tenant=${encodeURIComponent(tenant)}&id=${encodeURIComponent(backup.backup_uuid)}`
            : `/app/pbx_backups/download.php?id=${encodeURIComponent(backup.backup_uuid)}`;
          entry.append(link);
        }
        if (!entry.querySelector('form') && !entry.querySelector('[data-restore-options]')) {
          const link = node('a', 'Open restore options', 'setup-button');
          link.href = `/app/pbx_protection/?tenant=${encodeURIComponent(tenant)}#backup-${backup.backup_uuid}`;
          link.dataset.restoreOptions = 'true';
          entry.append(link);
        }
      }
      if (list?.children.length) root.querySelector('[data-no-backups]')?.remove();
      const requests = root.querySelector('[data-backup-jobs]');
      if (requests) {
        requests.replaceChildren(...jobs.map(job => {
          const item = node('p');
          item.append(node('strong', `${labels[job.action] || 'Backup request'} · ${states[job.status] || job.status}`),
            node('br'), node('span', job.message || ''), node('br'), node('small', job.created_at || ''));
          return item;
        }));
      }
    } catch {
      notice.textContent = 'Progress is temporarily unavailable. Your request continues on the server. Use Refresh to check again.';
    } finally {
      if (!stopped) setTimeout(refresh, 15000);
    }
  }
  refresh();
})();
