#!/usr/bin/env python3
"""Compare private qualification snapshots exactly; emit only closed diagnostics."""
import json
import sys


SECTIONS = ('identity', 'roles', 'memberships', 'schema', 'tables', 'columns',
            'values', 'table_count')
CRITICAL_TABLES = (
    'v_vars', 'v_default_settings', 'v_domain_settings', 'v_domains', 'v_users',
    'v_extensions', 'v_gateways', 'v_dialplans', 'v_dialplan_details',
    'v_sip_profiles', 'v_sip_profile_settings', 'v_permissions', 'v_groups',
    'v_group_permissions', 'v_user_groups', 'v_menu', 'v_menu_items',
    'v_pbx_tenants', 'v_pbx_tenant_users', 'v_pbx_services', 'v_pbx_templates',
    'v_pbx_service_assignments', 'v_pbx_setup_templates', 'v_pbx_restore',
    'v_pbx_sip_domains',
)
LIMIT = 100000
PUBLIC_COLUMNS = {
    table: ('insert_date', 'update_date', 'insert_user', 'update_user')
    for table in CRITICAL_TABLES
}
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
