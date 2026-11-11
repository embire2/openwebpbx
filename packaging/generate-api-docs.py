#!/usr/bin/env python3
"""Render the implemented v2 OpenAPI contract into the existing static public reference."""
from pathlib import Path
import html,json,re
root=Path(__file__).resolve().parents[1]
spec=json.loads((root/'website/public/api-openapi-v2.json').read_text())
esc=lambda x:html.escape(str(x),quote=True)
def resolve(schema):
    if '$ref' in schema:return spec['components']['schemas'][schema['$ref'].split('/')[-1]]
    return schema
def fields(schema):
    schema=resolve(schema);props=schema.get('properties',{});required=schema.get('required',[])
    if not props:return '<p>JSON object. Use the named command fields described below; unknown settings never grant additional privileges.</p>'
    rows=[]
    for name,p in props.items():
        p=resolve(p);kind=p.get('type','object' if 'properties' in p else 'value');rules=p.get('description','')
        if 'enum' in p:rules+=' Allowed: '+', '.join(map(str,p['enum']))
        if 'const' in p:rules+=' Must be '+str(p['const']).lower()+'.'
        if 'minimum' in p:rules+=' Minimum '+str(p['minimum'])+'.'
        if 'maximum' in p:rules+=' Maximum '+str(p['maximum'])+'.'
        if 'pattern' in p:rules+=' Pattern: '+p['pattern']
        if 'maxLength' in p:rules+=' Maximum '+str(p['maxLength'])+' characters.'
        rows.append(f'<tr><td><code>{esc(name)}</code></td><td>{esc(kind)}</td><td>{"Required" if name in required else "Optional"}</td><td>{esc(rules)}</td></tr>')
    return '<div class="api-table-wrap"><table class="api-table"><thead><tr><th>Body field</th><th>Type</th><th>Presence</th><th>Rules</th></tr></thead><tbody>'+''.join(rows)+'</tbody></table></div>'
intro='''<section id="administration-v2" class="api-section"><h2>Comprehensive API · Debian 1.0.26</h2>
<p>Manage tenant workspaces, PBX administration, department staff and personal calling accounts through the same role-checked services as the dashboards. Hosted API base: <code>https://openwebpbx.com/api/v2</code>. The existing <code>https://call.openweb.co.za/api/v2</code> remains supported. Self-hosted installations use their own installation hostname.</p>
<p><a href="/api-openapi-v2.json">Download complete OpenAPI 3.1 specification</a> · <a href="#v2-reference">Browse all v2 endpoints</a> · <a href="#reference">Registration and installation API v1</a></p>
<h3>Create and use an API key</h3><ol><li>Sign in to Tenant Admin, PBX Administration or My PBX and open <strong>API Keys</strong>.</li><li>Choose a name, expiry and the minimum permissions your integration needs. Administrative keys select a tenant and optional PBX. Personal and staff keys are automatically bound to their own account and PBX.</li><li>Copy the secret once and store it in your application’s secret store. Send it in <code>Authorization: Bearer &lt;key&gt;</code>; never put it in the URL.</li><li>Start with <code>GET /capabilities</code> and a read request. Save the returned PBX UUID for administrator endpoints; personal endpoints use <code>/me</code> without accepting another user’s UUID.</li></ol>
<div class="api-table-wrap"><table class="api-table"><thead><tr><th>Account</th><th>Allowed API management</th><th>Boundary</th></tr></thead><tbody>
<tr><td>Instance administrator</td><td>Tenant invitations, reseller authority, global SMTP, update policies and full recovery, plus permitted PBXs</td><td>Requires an instance-wide key and system:manage; backup actions also need backup scopes</td></tr>
<tr><td>Tenant administrator / reseller</td><td>Own templates, services, packages, backups and explicitly assigned customers</td><td>Current ownership, active parent workspace and reseller assignment; no global server access</td></tr>
<tr><td>PBX administrator</td><td>Users, SIP trunks, DIDs, routing, groups, queues, office hours, greetings, Call Me Back, hotel services, conferences, media and phone management</td><td>Selected PBX and current administrator permissions</td></tr>
<tr><td>Department owner / administrator / manager / supervisor / receptionist</td><td>Only actions permitted by their existing department roles</td><td>Department memberships are checked on every request; a staff key cannot use unrestricted /pbx administration</td></tr>
<tr><td>End user</td><td>Own status, queue membership, live calls, call history, voicemail, app profiles/password/QR, personal contacts, speed dials and conferences</td><td>Own enabled extension linked by the administrator’s Staff Access assignment; no account impersonation</td></tr>
</tbody></table></div>
<h3>Coverage</h3><p>The endpoint reference covers tenant onboarding and email verification (v1), templates and service creation, reseller packages and resource approvals, API keys, extensions, SIP providers and DIDs, ring groups, queues and callbacks, digital receptionists, departments and schedules, routing previews, recordings and voicemail, Keoma greetings, hotel services, audio/video conferences, phone recovery and migration, global mail, updates and encrypted backup/restore. Native phones continue to use the existing device-authenticated mobile API and SIP media services; a REST key is not a replacement for a SIP login.</p>
<h3>Permission and data rules</h3><p>Every request rechecks the key, expiry, owner account, live role, tenant availability and selected PBX. Revoked or moved staff lose access. Personal/department scopes cannot be mixed with administrator scopes. A child key cannot exceed its parent’s scopes, tenant/PBX boundary or expiry; parent revocation also withdraws descendants. List responses remove phone/provider passwords and server paths. Explicit QR/credential/invitation actions return private connection material only with their required scopes.</p>
<p>Viewing, scanning or emailing a QR code does not rotate it. A QR reset requires its separate explicit endpoint, write scope and <code>confirmed: true</code>. Changing an app password preserves desk-phone SIP passwords and follows the existing app-device revocation rules.</p>
<h3>Requests, jobs and recovery</h3><p>Use HTTPS with server-to-server requests. Browser Origin calls and query-string tokens are rejected. Each key allows 120 requests per minute; excess requests return <code>429</code> and <code>Retry-After: 60</code>. JSON requests are limited to 128 KiB. Replies contain <code>data</code> and <code>request_id</code>; error replies contain a safe code/message and request ID. List pagination starts at <code>page=0</code>.</p>
<p>POST commands use validated form fields, not arbitrary JSON merge patches. Send the complete settings you intend to save. Read projections deliberately omit secrets and are not private configuration exports. Destructive operations require the documented confirmation. Backup/restore, mail, greeting generation and update requests may queue jobs: an accepted request is not proof of completed restoration, email delivery or installation. Verify backup state before confirmed restoration. Full recovery revokes machine API keys. API keys cannot execute arbitrary SQL or FreeSWITCH commands.</p>
<h3>Quick examples</h3><div class="api-code"><pre><code>curl --fail-with-body -H "Authorization: Bearer $OPENWEBPBX_API_KEY" \\
  https://openwebpbx.com/api/v2/capabilities

# A personal key: the account is derived from the key
curl --fail-with-body -H "Authorization: Bearer $OPENWEBPBX_API_KEY" \\
  https://openwebpbx.com/api/v2/me

# PBX administrator: supply the domain_uuid from your key or service list
curl --fail-with-body -H "Authorization: Bearer $OPENWEBPBX_API_KEY" \\
  "https://openwebpbx.com/api/v2/pbx/$DOMAIN_UUID/users"</code></pre></div></section>'''
parts=['<section id="v2-reference" class="api-section"><h2>Complete v2 endpoint reference</h2><div class="api-filter" data-api-filter hidden><label for="api-filter">Find an endpoint</label><input id="api-filter" type="search" placeholder="Search voicemail, trunks, tenants, /me…" autocomplete="off"><p data-api-count aria-live="polite"></p></div><p>'+str(len(spec['paths']))+' paths. Search uses the filter below alongside the v1 reference. Each operation shows its verb, required scope, parameters and request fields. Download the OpenAPI file for response schemas and integration tooling.</p>']
for path,verbs in spec['paths'].items():
    for verb,op in verbs.items():
        endpoint='v2-'+op['operationId'];scope=op['x-required-scope']
        parts.append(f'<details class="api-endpoint" id="{esc(endpoint)}" data-api-endpoint><summary><span class="api-method api-method-{verb}">{verb.upper()}</span><span class="api-endpoint-route">/api/v2{esc(path)}</span><span class="api-auth">{esc(scope)}</span></summary><div class="api-endpoint-body"><h3>{esc(op["summary"])}</h3><p>{esc(op["description"])}</p>')
        params=op.get('parameters',[])
        if params:parts.append('<p>Parameters: '+', '.join('<code>'+esc(p['name'])+'</code> ('+esc(p['in'])+(', required' if p.get('required') else ', optional')+')' for p in params)+'.</p>')
        for mime,body in op.get('requestBody',{}).get('content',{}).items():
            parts.append('<p>Content-Type: <code>'+esc(mime)+'</code></p>'+fields(body['schema']))
            if 'example' in body:parts.append('<div class="api-code"><pre><code>'+esc(json.dumps(body['example'],indent=2))+'</code></pre></div>')
        parts.append('<p>Responses: '+', '.join('<code>'+esc(x)+'</code>' for x in op['responses'])+'.</p></div></details>')
parts.append('</section>')
p=root/'website/public/api-docs.html';source=p.read_text();source=re.sub(r'<section id="administration-v2".*?</section>',lambda _:intro,source,flags=re.S,count=1)
source=re.sub(r'<section id="v2-reference".*?</section>','',source,flags=re.S)
source=re.sub(r'<div class="api-filter" data-api-filter hidden>.*?</div>','',source,flags=re.S)
source=source.replace('<section id="quick-start"',''.join(parts)+'\n<section id="quick-start"',1)
source=re.sub(r'<h1[^>]*>.*?</h1>','<h1>Every PBX.<br>One comprehensive API.</h1>',source,count=1,flags=re.S)
source=source.replace('Hosted 1.0.25','Hosted 1.0.26').replace('API v2 · Debian 1.0.25','API v2 · Debian 1.0.26')
source=source.replace('<title>Tenant API — OpenWeb PBX</title>','<title>API Documentation — OpenWeb PBX</title>')
p.write_text(source)
print('Rendered',len(spec['paths']),'v2 paths;',len(source),'HTML bytes; original v1/legal sections preserved')
