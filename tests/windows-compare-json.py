#!/usr/bin/env python3
"""Compare private qualification snapshots exactly; emit only closed diagnostics."""
import json
import re
import sys
from collections import Counter


SECTIONS = ('identity', 'roles', 'memberships', 'schema', 'tables', 'columns',
            'values', 'table_count')
CRITICAL_TABLES = (
    'v_vars', 'v_default_settings', 'v_domain_settings', 'v_domains', 'v_users',
    'v_extensions', 'v_gateways', 'v_dialplans', 'v_dialplan_details',
    'v_sip_profiles', 'v_sip_profile_settings', 'v_permissions', 'v_groups',
    'v_group_permissions', 'v_user_groups', 'v_menu', 'v_menu_items',
    'v_pbx_tenants', 'v_pbx_tenant_users', 'v_pbx_services', 'v_pbx_templates',
    'v_pbx_service_assignments', 'v_pbx_setup_templates', 'v_pbx_restore',
    'v_pbx_sip_domains', 'v_pbx_greeting_status',
)
LIMIT = 100000
FILE_FIELDS = ('acl', 'sha256', 'bytes', 'directory', 'added', 'removed', 'shape', 'other')
FILE_CATEGORIES = ('web', 'server', 'desktop', 'tools', 'updater', 'config',
                   'notifications', 'media', 'native', 'backup_runtime', 'acme_runtime', 'other')
ADDED_KINDS = ('python_bytecode', 'dll', 'pyd', 'other_file',
               'python_cache_directory', 'other_directory', 'shape')
REMOVED_KINDS = ('temporary_control_request_json', 'other_file', 'directory', 'shape')
# Classification only: these public fixed paths never affect equality.
KNOWN_FILE_PATHS = {
    'c:/programdata/openwebpbx/' + name + '.json': label
    for name, label in (('installation', 'installation'), ('runtime', 'runtime'),
                        ('updater-install', 'updater_install'), ('native-engine', 'native_engine'),
                        ('local-codec', 'local_codec'), ('phone-tls', 'phone_tls_metadata'))
}
KNOWN_FILE_PATHS.update({
    'c:/openwebpbx': 'program_root',
    'c:/openwebpbx/php/php.ini': 'php_ini',
    'c:/openwebpbx/php/extras/ssl/openssl.cnf': 'php_openssl',
    'c:/openwebpbx/php/extras/ssl/cacert.pem': 'php_cacert',
    'c:/programdata/openwebpbx/mobile-notifications': 'notification_store',
    'c:/programdata/openwebpbx/mobile-notifications/config.json': 'notification_config',
    'c:/programdata/openwebpbx/mobile-notifications/config.json.lock': 'notification_lock',
    'c:/programdata/fusionpbx': 'fusionpbx_root',
    'c:/programdata/fusionpbx/config.conf': 'fusionpbx_config',
    'c:/programdata/fusionpbx/openweb-template.key': 'fusionpbx_template_key',
    'c:/programdata/openwebpbx/automatic-backups/worker.lock': 'automatic_backups_worker_lock',
    'c:/programdata/openwebpbx/storage': 'storage_root',
    'c:/programdata/openwebpbx/storage/openweb-music': 'stock_music_root',
    'c:/programdata/openwebpbx/storage/openweb-music/readme.md': 'stock_music_readme',
    'c:/programdata/openwebpbx/storage/openweb-music/manifest.json': 'stock_music_manifest',
    'c:/program files/freeswitch/sounds': 'stock_sounds_root',
    'c:/program files/freeswitch/sounds/openwebpbx': 'stock_sounds_openwebpbx',
})
CONFIG_SCOPES = {
    'c:/programdata/fusionpbx': 'fusionpbx',
    **{'c:/programdata/openwebpbx/' + name: name.replace('-', '_')
       for name in ('phone-tls', 'public-access', 'automatic-backups', 'backup-restore',
                    'backup-control', 'backup-downloads', 'codec-compiler-cache', 'codec-build')},
}
for _path, _label in CONFIG_SCOPES.items():
    KNOWN_FILE_PATHS.setdefault(_path, _label + '_root')
for _rate in (8000, 16000, 32000, 48000):
    _directory = 'c:/programdata/openwebpbx/storage/openweb-music/' + str(_rate)
    KNOWN_FILE_PATHS[_directory] = 'stock_music_' + str(_rate) + '_dir'
    KNOWN_FILE_PATHS[_directory + '/lofi-beat-loop-schmoop.wav'] = 'stock_music_' + str(_rate) + '_track'
KNOWN_FILE_LABELS = tuple(KNOWN_FILE_PATHS.values())


PUBLIC_COLUMNS = {
    table: ('insert_date', 'update_date', 'insert_user', 'update_user')
    for table in CRITICAL_TABLES
}
PUBLIC_COLUMNS['v_pbx_greeting_status'] = ('singleton', 'provider_configured', 'checked_at')
PUBLIC_COLUMNS['v_vars'] += ('var_uuid', 'var_category', 'var_name', 'var_value',
                             'var_order', 'var_enabled', 'var_description')
PUBLIC_COLUMNS['v_default_settings'] += (
    'default_setting_uuid', 'default_setting_category', 'default_setting_subcategory',
    'default_setting_name', 'default_setting_value', 'default_setting_order',
    'default_setting_enabled', 'default_setting_description',
)


def changed_keys(before, after):
    # Membership distinguishes a missing entry from an explicit JSON null.
    return {key for key in before.keys() | after.keys()
            if key not in before or key not in after or before[key] != after[key]}


def file_category(path):
    """Return fixed labels only; never return any supplied path component."""
    if not isinstance(path, str) or len(path) > 4096:
        return None
    path = path.replace('\\', '/').casefold()
    prefixes = (
        ('c:/openwebpbx/web', 'web'), ('c:/openwebpbx/server', 'server'),
        ('c:/openwebpbx/desktop', 'desktop'), ('c:/openwebpbx/tools', 'tools'),
        ('c:/openwebpbx/updater', 'updater'),
        ('c:/openwebpbx/backup-runtime', 'backup_runtime'), ('c:/openwebpbx/acme', 'acme_runtime'),
        ('c:/programdata/fusionpbx', 'config'),
        ('c:/programdata/openwebpbx/mobile-notifications', 'notifications'),
        ('c:/programdata/openwebpbx/storage', 'media'),
        ('c:/program files/freeswitch/sounds/openwebpbx', 'media'),
        ('c:/program files/freeswitch', 'native'),
        ('c:/programdata/openwebpbx', 'config'), ('c:/openwebpbx', 'other'),
    )
    for prefix, category in prefixes:
        if path == prefix or path.startswith(prefix + '/'):
            return category
    return None


def file_difference(before, after, changed):
    # A DB/task/general snapshot has no known absolute file entry with this
    # exact producer shape. Keep its existing report unchanged.
    if not any(file_category(name) is not None and isinstance(entry, dict)
               and isinstance(entry.get('acl'), str)
               and type(entry.get('directory')) is bool
               for side in (before, after) for name, entry in side.items()):
        return {}
    fields, categories = Counter(), Counter()
    category_fields, known_fields, scope_fields, added_kinds, removed_kinds = {}, {}, {}, {}, {}
    unknown = 0
    for name in changed:
        category = file_category(name) or 'other'
        categories[category] += 1
        label = (KNOWN_FILE_PATHS.get(name.replace('\\', '/').casefold())
                 if isinstance(name, str) and len(name) <= 4096 else None)
        unknown += label is None
        if name not in before:
            entry_fields = {'added'}
            entry = after[name]
            kind = 'shape'
            if isinstance(entry, dict) and type(entry.get('directory')) is bool:
                folded = name.replace('\\', '/').casefold() if isinstance(name, str) else ''
                if entry['directory']:
                    kind = ('python_cache_directory' if folded.endswith('/__pycache__')
                            else 'other_directory')
                else:
                    kind = ('python_bytecode' if folded.endswith(('.pyc', '.pyo'))
                            else 'dll' if folded.endswith('.dll')
                            else 'pyd' if folded.endswith('.pyd') else 'other_file')
            added_kinds.setdefault(category, Counter())[kind] += 1
        elif name not in after:
            entry_fields = {'removed'}
        else:
            left, right = before[name], after[name]
            if not isinstance(left, dict) or not isinstance(right, dict):
                entry_fields = {'shape'}
            else:
                keys = changed_keys(left, right)
                entry_fields = keys & {'acl', 'sha256', 'bytes', 'directory'}
                if keys - {'acl', 'sha256', 'bytes', 'directory'}:
                    entry_fields.add('other')
        fields.update(entry_fields)
        category_fields.setdefault(category, Counter()).update(entry_fields)
        if label is not None:
            known_fields.setdefault(label, Counter()).update(entry_fields)
        if isinstance(name, str) and len(name) <= 4096:
            folded = name.replace('\\', '/').casefold()
            for prefix, scope in CONFIG_SCOPES.items():
                if folded == prefix or folded.startswith(prefix + '/'):
                    scope_fields.setdefault(scope, Counter()).update(entry_fields)
                    if name in before and name not in after:
                        entry = before[name]
                        kind = 'shape'
                        if isinstance(entry, dict) and type(entry.get('directory')) is bool:
                            kind = 'directory' if entry['directory'] else 'other_file'
                            # A matching temporary filename is a discriminator,
                            # not proof of ownership/lifetime or an exemption.
                            if (not entry['directory'] and scope == 'backup_control'
                                    and re.fullmatch(r'tmp[a-z0-9_]{8}\.json', folded[len(prefix) + 1:])):
                                kind = 'temporary_control_request_json'
                        removed_kinds.setdefault(scope, Counter())[kind] += 1
                    break
    return {
        'comparison_files_observed': True,
        'comparison_changed_file_entry_count': min(len(changed), LIMIT),
        'comparison_file_counts_capped': (len(changed) > LIMIT
                                        or any(n > LIMIT for n in (*fields.values(), *categories.values()))),
        'comparison_file_field_counts': {name: min(fields[name], LIMIT) for name in FILE_FIELDS if fields[name]},
        'comparison_file_category_counts': {name: min(categories[name], LIMIT) for name in FILE_CATEGORIES if categories[name]},
        'comparison_file_category_field_counts': {category: {field: min(category_fields[category][field], LIMIT) for field in FILE_FIELDS if category_fields[category][field]} for category in FILE_CATEGORIES if category in category_fields},
        'comparison_known_file_field_counts': {label: {field: min(known_fields[label][field], LIMIT) for field in FILE_FIELDS if known_fields[label][field]} for label in KNOWN_FILE_LABELS if label in known_fields},
        'comparison_unknown_file_entry_count': min(unknown, LIMIT),
        'comparison_config_scope_field_counts': {scope: {field: min(scope_fields[scope][field], LIMIT) for field in FILE_FIELDS if scope_fields[scope][field]} for scope in CONFIG_SCOPES.values() if scope in scope_fields},
        'comparison_file_category_added_kind_counts': {category: {kind: min(added_kinds[category][kind], LIMIT) for kind in ADDED_KINDS if added_kinds[category][kind]} for category in FILE_CATEGORIES if category in added_kinds},
        'comparison_config_scope_removed_kind_counts': {scope: {kind: min(removed_kinds[scope][kind], LIMIT) for kind in REMOVED_KINDS if removed_kinds[scope][kind]} for scope in CONFIG_SCOPES.values() if scope in removed_kinds},
    }


def column_difference(paths, tables):
    """Optional private evidence cannot change the exact comparison outcome."""
    safe = {'comparison_columns_observed': False,
            'comparison_changed_column_count': 0,
            'comparison_critical_columns': [],
            'comparison_other_column_count': 0,
            'comparison_column_counts_capped': False}
    if len(paths) != 2:
        return safe
    try:
        sides = []
        for path in paths:
            with open(path, encoding='utf-8-sig') as stream:
                # Do not read arbitrary unbounded auxiliary files.
                text = stream.read(16 * 1024 * 1024 + 1)
            if len(text) > 16 * 1024 * 1024:
                return safe
            row = json.loads(text)
            if (not isinstance(row, dict) or set(row) != {'schema', 'producer', 'tables'}
                    or type(row['schema']) is not int or row['schema'] != 1
                    or row['producer'] != 'windows-private-column-hmac'
                    or not isinstance(row['tables'], dict)):
                return safe
            sides.append(row['tables'])
        changed = set()
        for table in tables:
            left, right = sides[0].get(table), sides[1].get(table)
            if not isinstance(left, dict) or not isinstance(right, dict):
                return safe
            for side in (left, right):
                if any(not isinstance(value, str) or len(value) != 64
                       or any(char not in '0123456789abcdef' for char in value)
                       for value in side.values()):
                    return safe
            changed.update((table, column) for column in changed_keys(left, right))
        public = [(table, column) for table in CRITICAL_TABLES
                  for column in PUBLIC_COLUMNS[table] if (table, column) in changed]
        other = len(changed) - len(public)
        safe.update(comparison_columns_observed=True,
                    comparison_changed_column_count=min(len(changed), LIMIT),
                    comparison_critical_columns=[table + '.' + column for table, column in public],
                    comparison_other_column_count=min(other, LIMIT),
                    comparison_column_counts_capped=len(changed) > LIMIT or other > LIMIT)
    except Exception:
        pass
    return safe


def difference(before, after, sidecars=()):
    result = {'comparison_changed_sections': [],
              'comparison_unknown_section_count': 0,
              'comparison_values_observed': False,
              'comparison_changed_values_table_count': 0,
              'comparison_critical_tables': [],
              'comparison_other_table_count': 0,
              'comparison_counts_capped': False}
    if isinstance(before, dict) and isinstance(after, dict):
        changed = changed_keys(before, after)
        result['comparison_changed_sections'] = [name for name in SECTIONS if name in changed]
        unknown = len(changed - set(SECTIONS))
        result['comparison_unknown_section_count'] = min(unknown, LIMIT)
        result['comparison_counts_capped'] = unknown > LIMIT
        try:
            result.update(file_difference(before, after, changed))
        except Exception:
            # Optional classification must never replace the original mismatch.
            pass
        left, right = before.get('values'), after.get('values')
        if isinstance(left, dict) and isinstance(right, dict):
            result['comparison_values_observed'] = True
            tables = changed_keys(left, right)
            other = len(tables - set(CRITICAL_TABLES))
            result['comparison_changed_values_table_count'] = min(len(tables), LIMIT)
            result['comparison_critical_tables'] = [name for name in CRITICAL_TABLES if name in tables]
            result['comparison_other_table_count'] = min(other, LIMIT)
            result['comparison_counts_capped'] |= len(tables) > LIMIT or other > LIMIT
            result.update(column_difference(sidecars, tables))
    for field, value in column_difference((), ()).items():
        result.setdefault(field, value)
    return result


def main(arguments):
    record = {'schema': 1, 'producer': 'windows-exact-json-comparison',
              'comparison_result': 'error', 'comparison_stage': 'usage'}
    code = 2
    try:
        if len(arguments) not in (2, 4):
            raise ValueError('Exactly two private snapshot paths are required.')
        snapshots = []
        for path, side in zip(arguments[:2], ('before', 'after')):
            record['comparison_stage'] = 'read_' + side
            with open(path, encoding='utf-8-sig') as stream:
                record['comparison_stage'] = 'parse_' + side
                snapshots.append(json.load(stream))
        record['comparison_stage'] = 'compare'
        # This is the original qualification predicate, without normalization,
        # exclusions, scalar conversion or schema/value projection.
        equal = snapshots[0] == snapshots[1]
        record['comparison_result'] = 'equal' if equal else 'different'
        code = 0 if equal else 1
        if not equal:
            record.update(difference(*snapshots, arguments[2:]))
    except Exception as error:
        record['comparison_result'] = 'error'
        kind = type(error).__name__
        record['comparison_error_type'] = kind if kind in {
            'OSError', 'FileNotFoundError', 'PermissionError', 'UnicodeDecodeError',
            'JSONDecodeError', 'RecursionError', 'ValueError', 'TypeError',
        } else 'ExternalError'
        code = 2
    print(json.dumps(record, ensure_ascii=True, separators=(',', ':')))
    return code


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
