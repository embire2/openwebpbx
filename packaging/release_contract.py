"""Describe and check complete OS installers, independently of upgrade offers."""
import json
from pathlib import Path
import re


COMPONENTS = [
    'web-administration', 'native-call-core', 'calling-engine',
    'local-postgresql-setup', 'automatic-updater', 'guided-registration',
    'backup-and-restore', 'tenant-administration', 'role-scoped-api',
    'offline-voice-prompts',
]
COMMON_FILES = {
    'VERSION', 'web/VERSION', 'LICENSE', 'README.txt', 'bootstrap.php',
    'web/resources/require.php', 'web/api/v2/index.php',
    'web/resources/classes/pbx_admin.php',
    'web/resources/classes/pbx_account_api.php',
    'web/app/pbx_setup/index.php', 'web/app/pbx_protection/index.php',
    'web/app/pbx_updates/index.php', 'verify_feed.py', 'release-public.pem',
    'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/configuration/acl.conf.lua',
    'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/dialplan/dialplan.lua',
    'web/app/pbx_setup/resources/switch/scripts/app/pbx_setup/policy.lua',
    'voices/1.0.2/pack.json', 'voice-tools/deployment.py',
    'voice-tools/voicepack.py', 'release_contract.py', 'installation.json',
}
DEBIAN_FILES = {
    'install.sh', 'install-check.py', 'configure.py', 'engine.tar.gz',
    'engine-dependencies.txt', 'server/OpenWebPbx.Server',
    'updater/OpenWebPbx.Updater', 'freeswitch.service', 'openwebpbx.service',
    'nginx.conf', 'upgrade.py', 'upgrade.sh', 'install-support.py',
    'install-voices.py', 'install-backups.sh', 'backups.py',
    'install-reseller.py', 'openwebpbx-uploads.pool.conf',
    'openwebpbx-protection.service', 'openwebpbx-protection.timer',
    'install-onboarding.py', 'onboarding.py', 'onboarding.php',
    'webhotel-onboarding.py', 'openwebpbx-onboarding.service',
    'openwebpbx-onboarding.timer', 'install-tenant-domains.py',
    'tenant-domains.py', 'tenant-domains-nginx.conf',
    'install-mail.py', 'install-phone-health.py', 'phone-health.py',
    'install-stun.py', 'openwebpbx-stun.service', 'openwebpbx-stun.conf',
    'install-meet.py', 'meet-nginx.conf', 'install-mobile-notifications.py',
    'openwebpbx-updater.service', 'openwebpbx-update-recovery.service',
    'openwebpbx-backups.service', 'openwebpbx-backups.timer',
}
WINDOWS_FILES = {
    'Start-OpenWebPBX.cmd', 'Install-OpenWebPBX.ps1',
    'Upgrade-OpenWebPBX.ps1', 'Install-Updater.ps1',
    'Install-NativeEngine.ps1', 'Install-Backups.ps1', 'backups.py',
    'Install-Onboarding.ps1', 'Install-TenantDomains.ps1',
    'Install-MailQueue.ps1', 'Install-PhoneHealth.ps1',
    'Install-Meet.ps1', 'Install-Voices.ps1',
    'server/OpenWebPbx.Server.exe', 'updater/OpenWebPbx.Updater.exe',
    'desktop/OpenWebPbx.Desktop.exe', 'engine/native-manifest.json',
    'backup-runtime/python.exe', 'acme/wacs.exe',
}


def contract(version, target):
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('The full installation version is invalid.')
    if target not in {'debian', 'windows'}:
        raise ValueError('The full installation platform is unsupported.')
    debian = target == 'debian'
    return {
        'schema': 1,
        'product': 'openwebpbx',
        'version': version,
        'platform': 'debian13-amd64' if debian else 'windows-x64',
        'package_type': 'full',
        'previous_installation_required': False,
        'entrypoint': 'install.sh' if debian else 'Start-OpenWebPBX.cmd',
        'database': {'engine': 'postgresql', 'location': 'local', 'setup': 'automatic'},
        'system_requirements': {
            'operating_system': 'Debian 13' if debian else 'Windows Server 2025 Desktop Experience',
            'architecture': 'amd64' if debian else 'x64',
            'administrator_access': True,
            'internet_connection': True,
        },
        'included_components': list(COMPONENTS),
    }


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('The full installation description contains a duplicate field.')
        result[key] = value
    return result


def validate_stage(stage, target, version):
    """Require the actual fresh-install components, not just a labelled patch."""
    stage = Path(stage)
    expected = contract(version, target)
    description = json.loads((stage / 'installation.json').read_text(), object_pairs_hook=unique_keys)
    if (description != expected or type(description.get('schema')) is not int
            or description.get('previous_installation_required') is not False
            or description['system_requirements'].get('administrator_access') is not True
            or description['system_requirements'].get('internet_connection') is not True):
        raise ValueError('The full installation description is invalid or inconsistent.')
    required = COMMON_FILES | (DEBIAN_FILES if target == 'debian' else WINDOWS_FILES)
    for name in sorted(required):
        path = stage / name
        if path.is_symlink() or not path.is_file() or not path.stat().st_size:
            raise ValueError('A full installation component is missing or invalid: ' + name)
    return description
