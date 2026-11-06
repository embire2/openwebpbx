#!/usr/bin/env python3
"""Exercise the actual installer against disposable paths and mocked systemd."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('reseller_install', Path(__file__).parents[1] / 'packaging/debian/install-reseller.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class Installer(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='owpbx-installer-')
        self.root = Path(self.tmp.name)
        self.package = self.root / 'package'; self.package.mkdir()
        self.site = self.root / 'site.conf'
        self.original = 'server {\n listen 80;\n}\nserver {\n listen 443 ssl;\n root /var/www/fusionpbx;\n # customer setting retained\n location / { try_files $uri $uri/ =404; }\n}\n'
        self.site.write_text(self.original)
        for n in m.PROGRAMS + ('openwebpbx-protection.service', 'openwebpbx-protection.timer'):
            (self.package / n).write_text('fixture ' + n)
        self.calls = []
        self.patch = patch.multiple(m, PACKAGE=self.package, TOOLS=self.root / 'tools',
            UNIT=self.root / 'openwebpbx-protection.service', TIMER=self.root / 'openwebpbx-protection.timer',
            POOL=self.root / 'openwebpbx-uploads.conf',
            SITES=(self.site, self.root / 'absent'), LINKS=[self.root / 'wanted.timer'], MAINTENANCE=self.root / 'maintenance', INBOX=self.root / 'inbox')
        self.patch.start()

    def tearDown(self):
        self.patch.stop(); self.tmp.cleanup()

    def run_command(self, args, **kwargs):
        self.calls.append(args)
        return subprocess.CompletedProcess(args, 0, 'disabled\n' if 'is-enabled' in args else '', '')

    def test_add_preserves_customer_bytes_and_is_idempotent(self):
        _, text = m.site_content()
        self.assertEqual(text.replace('\n' + m.API, '', 1), self.original)
        self.site.write_text(text)
        self.assertEqual(m.site_content()[1], text)

    def test_large_uploads_disable_php_pre_read(self):
        self.assertEqual(m.API.count('fastcgi_request_buffering off;'), 2)
        self.assertNotIn('PHP_ADMIN_VALUE', m.API)
        self.assertEqual(m.API.count('fastcgi_pass unix:/run/php/openwebpbx-uploads.sock;'), 3)
        self.assertEqual(m.API.count('auth_request /_openwebpbx/upload-authorize;'), 2)
        self.assertIn('fastcgi_pass_request_body off;', m.API)
        tenant=(Path(__file__).parents[1] / 'packaging/debian/tenant-domains-nginx.conf').read_text()
        self.assertIn('fastcgi_pass unix:/run/php/openwebpbx-uploads.sock;', tenant)
        self.assertNotIn('PHP_ADMIN_VALUE', tenant)
        pool=(Path(__file__).parents[1] / 'packaging/debian/openwebpbx-uploads.pool.conf').read_text()
        self.assertIn('php_admin_flag[enable_post_data_reading] = off', pool)
        self.assertIn('pm.max_children = 2', pool)

    def test_unknown_api_and_wrong_document_root_refused(self):
        self.site.write_text(self.original + '\nlocation /api/v2/ {}')
        with self.assertRaises(ValueError): m.site_content()

    def test_hosted_legacy_rewrite_exempts_both_versioned_apis(self):
        self.original = 'server {\n listen 443 ssl;\n if ($uri ~* "^(?!/api/v1/).*/api/.*$") { rewrite ^(.*)/api/(.*)$ $1/api/index.php last; }\n location / {\n root /var/www/fusionpbx/public;\n }\n}\n'
        self.site.write_text(self.original)
        _, text=m.site_content()
        self.assertIn('^(?!/api/v[12]/)', text)
        self.assertEqual(text.count(m.API), 1)
        self.assertEqual(text.replace(m.API, '', 1).replace('^(?!/api/v[12]/)', '^(?!/api/v1/)', 1), self.original)
        self.site.write_text(self.original.replace('/var/www/fusionpbx', '/foreign'))
        with self.assertRaises(ValueError): m.site_content()

    def test_missing_input_has_no_product_writes(self):
        (self.package / 'protection.py').unlink()
        with patch.object(m.subprocess, 'run', side_effect=self.run_command):
            with self.assertRaises(ValueError): m.install()
        self.assertEqual(self.site.read_text(), self.original)
        self.assertFalse(m.UNIT.exists())
        self.assertEqual(self.calls, [])

    def test_proxy_validation_failure_rolls_back_original_bytes(self):
        def fail(args, **kwargs):
            if args == ['nginx', '-t']: raise subprocess.CalledProcessError(1, args)
            return self.run_command(args, **kwargs)
        with patch.object(m.subprocess, 'run', side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError): m.install()
        self.assertEqual(self.site.read_text(), self.original)

    def test_invalid_php_pool_never_becomes_active(self):
        def fail(args, **kwargs):
            if args == ['php-fpm8.4', '-t']: raise subprocess.CalledProcessError(1, args)
            return self.run_command(args, **kwargs)
        with patch.object(m.subprocess, 'run', side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError): m.install(True)
        self.assertFalse(m.POOL.exists())
        self.assertEqual(self.site.read_text(), self.original)
        self.assertFalse(any(c[:2] == ['systemctl', 'reload'] for c in self.calls))

    def test_existing_disabled_timer_is_never_enabled_or_started(self):
        m.TIMER.write_bytes((self.package / m.TIMER.name).read_bytes())
        with patch.object(m.subprocess, 'run', side_effect=self.run_command): m.install(True)
        self.assertFalse(any(c[0] == 'systemctl' and c[1] in ('enable', 'start') for c in self.calls))
        self.assertIn(['systemctl', 'reload', 'nginx'], self.calls)

    def test_custom_task_is_preserved_before_any_write(self):
        m.TIMER.write_text('customer schedule and settings')
        with patch.object(m.subprocess, 'run', side_effect=self.run_command):
            with self.assertRaises(ValueError): m.install(True)
        self.assertEqual(m.TIMER.read_text(), 'customer schedule and settings')
        self.assertEqual(self.site.read_text(), self.original)
        self.assertFalse((m.TOOLS / 'protection.py').exists())
        self.assertEqual(self.calls, [])

    def test_new_timer_enabled_and_started_after_validation(self):
        with patch.object(m.subprocess, 'run', side_effect=self.run_command): m.install(True)
        self.assertEqual(m.INBOX.stat().st_mode & 0o777, 0o730)
        self.assertEqual(m.INBOX.stat().st_gid, 33)
        self.assertIn(['systemctl', 'enable', m.TIMER.name], self.calls)
        self.assertIn(['systemctl', 'start', m.TIMER.name], self.calls)

    def test_upload_inbox_custom_permissions_are_refused(self):
        m.INBOX.mkdir(mode=0o700)
        with self.assertRaises(ValueError): m.ensure_upload_inbox()
        self.assertEqual(m.INBOX.stat().st_mode & 0o777, 0o700)

    def test_linked_site_refused_before_write(self):
        other=self.root / 'other'; other.write_text(self.original)
        self.site.unlink(); self.site.symlink_to(other)
        with self.assertRaises(ValueError): m.site_content()
        self.assertEqual(other.read_text(), self.original)


if __name__ == '__main__': unittest.main()
