#!/usr/bin/env python3
"""Derive the tenant reference from the implemented administration API contract."""
from copy import deepcopy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TENANT_SCOPES = ['pbx:read', 'pbx:write', 'calls:control', 'credentials:read',
                 'backups:read', 'backups:write', 'templates:read', 'templates:write', 'keys:manage']


def reference(source):
    spec = deepcopy(source)
    spec['info'] = {
        'title': 'OpenWeb PBX Tenant Administration API', 'version': source['info']['version'],
        'description': 'Manage one tenant and all its CloudPBX services. A tenant-wide key has a tenant_uuid and no domain_uuid. Every request also checks the account current permissions and tenant/PBX availability. This reference excludes instance, reseller and personal-account operations. Registration and managed-domain authority remain in API v1. Full tenant administration never grants another tenant or server-wide settings.'}
    spec['servers'] = [{'url': 'https://call.openweb.co.za/api/v2', 'description': 'This PBX installation. Use its API Keys page to create a tenant-scoped key.'}]
    spec['paths'] = {}
    for path, methods in source['paths'].items():
        selected = {method: deepcopy(operation) for method, operation in methods.items()
                    if operation.get('x-required-scope') in [*TENANT_SCOPES, 'any']}
        if selected:
            spec['paths'][path] = selected
    # Delegation from a full-tenant key is limited to this profile's nine scopes.
    spec['components']['schemas']['KeyCreate']['properties']['scopes']['items']['enum'] = TENANT_SCOPES
    spec['x-tenant-admin-scopes'] = TENANT_SCOPES
    # Keep only schemas actually referenced by the selected operations.
    required = set()

    def references(value):
        if isinstance(value, dict):
            ref = value.get('$ref', '')
            if ref.startswith('#/components/schemas/'):
                name = ref.rsplit('/', 1)[1]
                if name not in required:
                    required.add(name)
                    references(spec['components']['schemas'][name])
            for item in value.values():
                references(item)
        elif isinstance(value, list):
            for item in value:
                references(item)
    references(spec['paths'])
    spec['components']['schemas'] = {name: schema for name, schema in spec['components']['schemas'].items() if name in required}
    return spec


if __name__ == '__main__':
    spec = reference(json.loads((ROOT / 'website/public/api-openapi-v2.json').read_text()))
    target = ROOT / 'app/pbx_api_docs/reference.json'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(spec, indent=2, ensure_ascii=False) + '\n')
    print(f'Exported {len(spec["paths"])} tenant paths / {sum(len(v) for v in spec["paths"].values())} operations.')
