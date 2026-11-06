#!/usr/bin/env python3
"""Validate the public commercial API contract and every published typed example."""
import json
from pathlib import Path
from jsonschema import Draft202012Validator, FormatChecker

spec = json.loads((Path(__file__).resolve().parents[1] / 'website/public/api-openapi-v2.json').read_text())
components = spec['components']
checks = 0
ids = []
for name, schema in components['schemas'].items():
    Draft202012Validator.check_schema(schema)
    checks += 1
for path, operations in spec['paths'].items():
    for method, operation in operations.items():
        ids.append(operation['operationId'])
        for name in ('id', 'tenant_uuid', 'domain_uuid'):
            if '{' + name + '}' in path:
                assert any(p['name'] == name and p['in'] == 'path' and p['required'] for p in operation.get('parameters', [])), path
                checks += 1
        for mime, content in operation.get('requestBody', {}).get('content', {}).items():
            if 'example' not in content:
                continue
            schema = {**content['schema'], 'components': components}
            validator = Draft202012Validator(schema, format_checker=FormatChecker())
            errors = list(validator.iter_errors(content['example']))
            assert not errors, (path, [e.message for e in errors])
            checks += 1
assert len(ids) == len(set(ids))
checks += 1
invalid = {
    'PlanSave': [dict(plan_name='Business', extension_limit=0, concurrent_calls=2), dict(plan_name='Business', extension_limit=10, concurrent_calls=2, extension_price_cents=1.5), dict(plan_name='Business', extension_limit=10, concurrent_calls=2, currency='zar')],
    'ResourceOrder': [dict(idempotency_key='order-0001', extra_calls=0, extra_extensions=0), dict(idempotency_key='short', extra_calls=1), dict(idempotency_key='order-0002', extra_extensions=-1)],
    'TenantRestore': [dict(password='example-only-password', confirm_tenant='Example', confirm_replace=False), dict(password='short', confirm_tenant='Example', confirm_replace=True)],
    'KeyCreate': [dict(name='Read only', scopes=['root:all']), dict(name='Missing scopes', scopes=[]), dict(name='No expiry', scopes=['pbx:read'], days=366)],
}
for name, examples in invalid.items():
    validator = Draft202012Validator({**components['schemas'][name], 'components': components}, format_checker=FormatChecker())
    for example in examples:
        assert list(validator.iter_errors(example)), (name, 'invalid request accepted')
        checks += 1
for path in ('/tenants/{tenant_uuid}/backups/import', '/instance/backups/import'):
    assert 'application/octet-stream' in spec['paths'][path]['post']['requestBody']['content']
    checks += 1
print(f'PASS {checks} OpenAPI schema/example/path controls; {len(spec["paths"])} implemented paths')
