#!/usr/bin/env python3
"""The local reference is a deterministic, tenant-only view of the public contract."""
import importlib.util
import json
from pathlib import Path
from jsonschema import Draft202012Validator, FormatChecker

root=Path(__file__).resolve().parents[1]
module=importlib.util.spec_from_file_location('tenant_reference',root/'tests/export_tenant_openapi.py')
export=importlib.util.module_from_spec(module);module.loader.exec_module(export)
source=json.loads((root/'website/public/api-openapi-v2.json').read_text())
actual=json.loads((root/'app/pbx_api_docs/reference.json').read_text())
assert actual==export.reference(source)
checks=1
for path,operations in actual['paths'].items():
    assert not path.startswith(('/instance','/resellers','/me','/staff'))
    for method,operation in operations.items():
        assert operation==source['paths'][path][method]
        assert operation['x-required-scope'] in [*export.TENANT_SCOPES,'any']
        checks+=2
        for content in operation.get('requestBody',{}).get('content',{}).values():
            if 'example' in content:
                schema={**content['schema'],'components':actual['components']}
                assert not list(Draft202012Validator(schema,format_checker=FormatChecker()).iter_errors(content['example']))
                checks+=1
for required in ['/services','/templates','/pbx/{domain_uuid}/users','/pbx/{domain_uuid}/trunks','/pbx/{domain_uuid}/dids','/pbx/{domain_uuid}/actions/call-me-back','/keys','/tenants/{tenant_uuid}/backups']:
    assert required in actual['paths'];checks+=1
assert 'post' not in actual['paths']['/tenants']
assert set(actual['components']['schemas']['KeyCreate']['properties']['scopes']['items']['enum'])==set(export.TENANT_SCOPES)
checks+=2
for name in ['app/tenant_services/index.php','app/pbx_setup/index.php','app/pbx_staff/index.php']:
    assert '<a href="/api-docs">API Documentation</a>' in (root/name).read_text();checks+=1
assert "['/api-docs', '/api-docs/index.php']" in (root/'public/index.php').read_text();checks+=1
print(f'PASS {checks} local tenant-reference schema, scope, parity and navigation controls; {len(actual["paths"])} paths')
