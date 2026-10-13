#!/usr/bin/env python3
"""Exclusive disposable restore tenant: real HTTPS ring-group form and CSRF checks."""
import html.parser
import http.cookiejar
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

try:
    from pbx_v20_restore_native import private_credentials
except ImportError:
    from native import private_credentials


class Forms(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms = []
        self.form = None
        self.select = None
        self.option = None

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == 'form':
            self.form = {'fields': [], 'attrs': attrs}
            self.forms.append(self.form)
        if self.form is None:
            return
        if tag == 'input' and attrs.get('name'):
            if attrs.get('type') not in ('checkbox', 'radio') or 'checked' in attrs:
                self.form['fields'].append((attrs['name'], attrs.get('value', '')))
            self.form.setdefault('inputs', []).append(attrs)
        if tag == 'select' and attrs.get('name'):
            self.select = {'name': attrs['name'], 'options': []}
        if tag == 'option' and self.select is not None:
            self.option = attrs
            self.select['options'].append(attrs)

    def handle_endtag(self, tag):
        if tag == 'select' and self.select is not None:
            options = self.select['options']
            selected = next((option for option in options if 'selected' in option), options[0] if options else {})
            self.form['fields'].append((self.select['name'], selected.get('value', '')))
            self.select = None
        if tag == 'form':
            self.form = None


def parse(page):
    forms = Forms()
    forms.feed(page)
    return forms.forms


def verify_inventory():
    result = subprocess.run(['/usr/bin/php', '/var/lib/openwebpbx/restore-phone112/fixture.php', 'verify'],
                            check=True, capture_output=True, text=True, timeout=30)
    report = json.loads(result.stdout)
    assert report['all_passed']
    return len(report['checks'])


def fixture(mode, *arguments):
    command = ['/usr/bin/php', '/var/lib/openwebpbx/restore-phone112/fixture.php', mode]
    command.extend(str(argument) for argument in arguments)
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=30)
    if mode in ('https-check', 'provider-check'):
        assert json.loads(result.stdout)['all_passed'], 'Phone-domain operation altered the restored inventory'


def connect_providers(session, base, state, checks):
    assert len(state['provider_fixture']['keys']) == 2
    for index, key in enumerate(state['provider_fixture']['keys']):
        path = base+'/app/pbx_setup/?'+urllib.parse.urlencode({'view': 'first_calls', 'trunk': key})

        def fields():
            page = session.get(path)
            page.raise_for_status()
            form = next(form for form in parse(page.text) if ('action', 'connect_provider') in form['fields'])
            return dict(form['fields'])

        original = fields()
        assert original['trunk'] == key and 'confirm_handover' not in original
        checks['owned_off_provider_'+str(index+1)+'_normal_handover_form'] = True
        if index == 0:
            refused = session.post(path, original)
            refused.raise_for_status()
            assert 'Confirm that you are ready' in refused.text
            fixture('provider-check', index, 'off')
            checks['missing_handover_confirmation_refused_without_mutation'] = True
            refused = session.post(path, [('action', 'connect_provider'), ('trunk', key), ('confirm_handover', '1')])
            assert refused.status_code == 403
            fixture('provider-check', index, 'off')
            checks['missing_csrf_handover_refused_without_mutation'] = True
        data = fields()
        data['confirm_handover'] = '1'
        saved = session.post(path, data)
        saved.raise_for_status()
        assert 'Provider and 1 incoming-number routes enabled.' in saved.text
        fixture('provider-check', index, 'on')
        checks['normal_https_atomically_connects_owned_provider_'+str(index+1)+'_and_number'] = True
        if index == 0:
            stale = session.post(path, data)
            assert stale.status_code == 403
            fixture('provider-check', index, 'on')
            checks['pre_handover_csrf_token_reuse_denied_without_mutation'] = True
            page = session.get(path)
            page.raise_for_status()
            form = next(form for form in parse(page.text) if ('action', 'network_check') in form['fields'])
            repeat_data = dict(form['fields'])
            repeat_data.update(action='connect_provider', trunk=key, confirm_handover='1')
            repeat = session.post(path, repeat_data)
            repeat.raise_for_status()
            assert 'already connected' in repeat.text
            fixture('provider-check', index, 'on')
            checks['active_provider_repeat_refused_without_mutation'] = True
    checks['all_original_19_providers_off_users_and_routes_preserved'] = True


def phone_domains(session, base, root, state, checks):
    fixture('https-prepare')
    state = json.loads((root/'state.json').read_text())
    alias = state['https_fixture']['alias']
    path = base+'/app/pbx_setup/?view=phones'

    def fields(action, address):
        page = session.get(path)
        page.raise_for_status()
        form = next(form for form in parse(page.text) if ('action', 'phone_domain') in form['fields'])
        data = dict(form['fields'])
        data.update(action=action, sip_domain=address)
        return data

    try:
        page = session.get(path)
        page.raise_for_status()
        assert 'Change phone domain' in page.text
        checks['normal_owned_phone_domain_form'] = True
        denied = session.post(path, [('action', 'phone_domain'), ('sip_domain', alias)])
        assert denied.status_code == 403
        fixture('https-check', 'absent')
        checks['missing_csrf_domain_save_denied_without_mutation'] = True
        for name in (state['home_realm'], state['https_fixture']['foreign_alias']):
            refused = session.post(path, fields('phone_domain', name))
            refused.raise_for_status()
            assert 'belongs to another PBX' in refused.text
            fixture('https-check', 'absent')
        checks['foreign_canonical_and_alias_refused_without_mutation'] = True
        saved = session.post(path, fields('phone_domain', '  '+alias.upper()+'.  '))
        saved.raise_for_status()
        assert 'Phone domain saved:' in saved.text and alias in saved.text
        fixture('https-check', 'enabled')
        checks['normal_https_normalizes_and_saves_owned_phone_domain'] = True
        subprocess.run(['/usr/bin/python3', str(root/'native.py'), '--source-phones', '--phone-domain-alias'],
                       check=True, capture_output=True, text=True, timeout=60)
        checks['both_actual_source_phones_register_and_call_with_only_https_phone_domain_change'] = True
        repeated = session.post(path, fields('phone_domain', alias))
        repeated.raise_for_status()
        fixture('https-check', 'enabled')
        checks['repeat_save_is_scoped_and_idempotent'] = True
        refused = session.post(path, [('action', 'disable_phone_domain'), ('sip_domain', alias)])
        assert refused.status_code == 403
        fixture('https-check', 'enabled')
        checks['missing_csrf_disable_denied_without_mutation'] = True
        disabled = session.post(path, fields('disable_phone_domain', alias))
        disabled.raise_for_status()
        assert 'Phone domain disabled.' in disabled.text
        fixture('https-check', 'disabled')
        checks['normal_https_disables_only_owned_alias_and_restores_primary'] = True
        anonymous = Session()
        denied = anonymous.post(path, [('action', 'phone_domain'), ('sip_domain', alias)])
        assert 'Change phone domain' not in denied.text and 'username' in denied.text
        fixture('https-check', 'disabled')
        anonymous.get(base+'/logout.php').raise_for_status()
        checks['anonymous_phone_domain_write_denied'] = True
        checks['canonical_users_credentials_routes_and_foreign_ownership_preserved'] = True
    finally:
        fixture('https-cleanup')
        verify_inventory()
    checks['owned_domain_fixtures_removed_and_full_source_inventory_preserved'] = True


class Session:
    def __init__(self):
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        tls.check_hostname = False
        tls.verify_mode = ssl.CERT_NONE
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                urllib.request.HTTPSHandler(context=tls),
                urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(self, url, data=None, timeout=15):
        request = urllib.request.Request(url, data=None if data is None else urllib.parse.urlencode(data).encode())
        try:
            response = self.opener.open(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            response = error
        return Response(response.status, response.read().decode('utf-8'), response.geturl())

    def get(self, url, timeout=15):
        return self.request(url, timeout=timeout)

    def post(self, url, data, timeout=15):
        return self.request(url, data, timeout)


class Response:
    def __init__(self, status, text, url):
        self.status_code, self.text, self.url = status, text, url

    def raise_for_status(self):
        assert self.status_code < 400, 'Owned HTTPS request failed; status '+str(self.status_code)


def main():
    os.umask(0o077)
    if not __debug__:
        raise RuntimeError('Qualification requires assertions enabled')
    if os.environ.get('OPENWEB_RESTORE_QUALIFICATION') != '1' or socket.gethostname() != 'owpbx-desk-restore112' or Path('/run/systemd/container').read_text().strip() != 'systemd-nspawn':
        raise RuntimeError('The exclusively owned disposable restore machine is required')
    root = Path('/var/lib/openwebpbx/restore-phone112')
    state = json.loads((root/'state.json').read_text())
    credentials = private_credentials(root, state)
    assert state['imported_provider_activation_forbidden']
    group = credentials['calling_objects']['ring_groups'][0]
    expected = [member['number'] for member in group['members']]
    checks = {}
    # HTTPS loopback in the isolated clone. This does not qualify public DNS/TLS.
    session = Session()
    base = 'https://127.0.0.1'
    result = session.get(base+'/login.php', timeout=15)
    result.raise_for_status()
    form = next(form for form in parse(result.text) if any(name == 'username' for name, _ in form['fields']))
    login = dict(form['fields'])
    login.update(username=credentials['owner']['email'], password=credentials['owner']['password'])
    result = session.post(base+'/login.php', data=login, timeout=15)
    result.raise_for_status()
    assert 'desktop-data' in result.text or '/core/desktop/' in result.url
    checks['normal_owned_tenant_login'] = True
    portal = session.get(base+'/app/tenant_services/', timeout=15)
    portal.raise_for_status()
    opening = next(form for form in parse(portal.text) if ('action', 'open') in form['fields']
                   and ('service_uuid', state['service']) in form['fields'])
    result = session.post(base+'/app/tenant_services/', data=opening['fields'], timeout=15)
    result.raise_for_status()
    assert 'desktop-data' in result.text or '/core/desktop/' in result.url
    checks['normal_csrf_scoped_owned_service_open'] = True
    if '--connect-provider' in sys.argv:
        try:
            connect_providers(session, base, state, checks)
        finally:
            session.get(base+'/logout.php').raise_for_status()
        checks['owned_https_session_logged_out'] = True
        report = {'fixture_only': True, 'normal_tenant_https': True,
                  'only_two_invented_loopback_providers_connected': True,
                  'all_original_19_providers_off': True,
                  'loopback_tls_not_public_certificate_qualification': True,
                  'private_owner_and_source_values_excluded': True, 'checks': checks,
                  'all_passed': bool(checks) and all(checks.values())}
        (root/'https-provider-handover-evidence.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
        return
    if '--phone-domains' in sys.argv:
        try:
            phone_domains(session, base, root, state, checks)
        finally:
            session.get(base+'/logout.php').raise_for_status()
        checks['owned_https_session_logged_out'] = True
        report = {'fixture_only': True, 'normal_tenant_https': True,
                  'restore_inventory_check_count': verify_inventory(),
                  'loopback_tls_not_public_certificate_qualification': True,
                  'private_owner_and_source_values_excluded': True, 'checks': checks,
                  'all_passed': bool(checks) and all(checks.values())}
        (root/'https-phone-domains-evidence.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
        return
    path = '/app/pbx_setup/?'+urllib.parse.urlencode({'view': 'ring_groups', 'edit': group['number']})
    result = session.get(base+path, timeout=15)
    result.raise_for_status()
    forms = parse(result.text)
    edit = next(form for form in forms if ('action', 'save') in form['fields'])
    values = [input['value'] for input in edit['inputs'] if input.get('name') == 'members[]']
    assert len(values) == len(credentials['users']) and len(set(values)) == len(values)
    assert set(values) == {user['number'] for user in credentials['users']}
    checks['all_member_checkboxes_submit_original_extension_numbers'] = True
    selected = [value for name, value in edit['fields'] if name == 'members[]']
    assert set(selected) == set(expected)
    checks['original_selected_members_rendered'] = True
    fields = edit['fields']
    without_csrf = [(name, value) for name, value in fields if name not in
                    {input['name'] for input in edit['inputs'] if input.get('type') == 'hidden' and input.get('name') != 'action'}]
    refused = session.post(base+path, data=without_csrf, timeout=15)
    assert refused.status_code == 403
    checks['missing_csrf_save_refused'] = True
    inventory_checks = verify_inventory()
    checks['missing_csrf_preserves_source_configuration'] = True
    saved = session.post(base+path, data=fields, timeout=15)
    saved.raise_for_status()
    assert 'Saved.' in saved.text
    checks['real_unchanged_ring_group_save'] = True
    result = session.get(base+path, timeout=15)
    result.raise_for_status()
    edit = next(form for form in parse(result.text) if ('action', 'save') in form['fields'])
    assert {value for name, value in edit['fields'] if name == 'members[]'} == set(expected)
    checks['original_members_persist_after_reload'] = True
    assert verify_inventory() == inventory_checks
    checks['all_restore_inventory_checks_preserved_after_save'] = True
    anonymous = Session()
    denied = anonymous.get(base+path, timeout=15)
    assert 'admin-members' not in denied.text and 'username' in denied.text
    checks['anonymous_group_editor_denied'] = True
    for owned_session in (session, anonymous):
        owned_session.get(base+'/logout.php', timeout=15).raise_for_status()
    checks['owned_https_sessions_logged_out'] = True
    report = {'fixture_only': True, 'normal_tenant_https': True,
              'restore_inventory_check_count': inventory_checks,
              'loopback_tls_not_public_certificate_qualification': True,
              'private_owner_and_source_values_excluded': True, 'checks': checks,
              'all_passed': bool(checks) and all(checks.values())}
    (root/'https-group-evidence.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
