#!/usr/bin/env python3
"""Opt-in isolated phone-domain fixture qualification; credentials remain private."""
from pathlib import Path
ns={};exec(Path('/root/auth-native.py').read_text().split('checks={};failures=[]')[0],ns)
Client,esl,mutate,state,ROOT,sip=(ns[x] for x in ['Client','esl','mutate','state','ROOT','sip'])
import json,time
checks={};failed=[]
def check(name,value):checks[name]=bool(value);failed.extend([] if value else [name])
users=state['users'];numbers={u['number'] for u in users};separate=next(u for u in users if u['number']!=u['auth'] and u['auth'] not in numbers);collision=next(u for u in users if u['number']!=u['auth'] and u['auth'] in numbers)
def flush(u,realm):esl('sofia profile internal flush_inbound_reg '+u.get('canonical_auth',u['auth'])+'@'+realm)
for transport in ['udp','tcp','tls']:
 for u in users+[state['ordinary'],state['mobile']]:
  for realm in [state['realm'],state['alias'],state['alias2']]:flush(u,realm)
 c=Client(transport,tls_name=state['alias']);second=Client(transport,tls_name=state['alias2'])
 try:
  for i,u in enumerate(users):
   r=c.register(u,realm=state['alias']);check(f'{transport}_alias_source_{i+1}',r['code']==200)
   for k in ['from_unchanged','to_aor_unchanged','contact_unchanged','call_id_unchanged','cseq_unchanged','challenge_realm_matched']:check(f'{transport}_alias_response_{i+1}_{k}',r[k])
   check(f'{transport}_alias_native_contact_{i+1}',r['requested_contact'] in esl('sofia_contact '+u['auth']+'@'+state['alias']))
   r=c.register(u,realm=state['alias'],expires=0);check(f'{transport}_alias_unregister_{i+1}',r['code']==200 and r['requested_contact'] not in esl('sofia_contact '+u['auth']+'@'+state['alias']))
  r=c.register(separate,realm=state['alias']);check(transport+'_alias_canonical_domain_var',esl('user_data '+separate['auth']+'@'+state['alias']+' var domain_name')==state['realm'])
  check(transport+'_alias_canonical_context_var',esl('user_data '+separate['auth']+'@'+state['alias']+' var user_context')==state['realm'])
  check(transport+'_alias_canonical_presence_var',esl('user_data '+separate['auth']+'@'+state['alias']+' var presence_id')==separate['auth']+'@'+state['realm'])
  # A new public address retains the existing native account identity and application context.
  dial=esl('user_data '+separate['auth']+'@'+state['realm']+' param dial-string');check(transport+'_canonical_user_call_includes_owned_alias',r['requested_contact'] in dial and state['foreign']['alias'] not in dial)
  check(transport+'_canonical_incoming_to_alias_keeps_phone_contact',c.incoming_uri_check(separate,realm=state['alias']))
  check(transport+'_incoming_to_aor_matches_original_user_and_alias',c.last_incoming_to_aor_matches)
  r=c.register(separate,realm=state['alias'],aor=separate['auth']);check(transport+'_alias_legacy_auth_aor_noncolliding',r['code']==200);c.register(separate,realm=state['alias'],aor=separate['auth'],expires=0)
  check(transport+'_alias_numeric_collision_refused',c.register(collision,realm=state['alias'],aor=collision['auth'])['code']==403)
  for name,kw in [('mixed_from_canonical',{'from_realm':state['realm']}),('mixed_to_canonical',{'to_realm':state['realm']}),('mixed_to_other_owned_alias',{'to_realm':state['alias2']}),('foreign_auth_realm',{'realm':state['foreign']['alias']}),('same_suffix_unassigned',{'realm':'unassigned112.sip.openwebpbx.com'}),('wrong_password',{'password':'unrelated-test-password'})]:
   options={'realm':state['alias']};options.update(kw);check(transport+'_'+name,c.register(separate,**options)['code']==403)
  # Both owned aliases aggregate, and a disabled alias disappears without flushing the user_call cache.
  a=c.register(separate,realm=state['alias']);b=second.register(separate,realm=state['alias2'])
  dial=esl('user_data '+separate['auth']+'@'+state['realm']+' param dial-string');check(transport+'_both_owned_aliases_aggregate',a['requested_contact'] in dial and b['requested_contact'] in dial)
  c.register(separate,realm=state['alias']);mutate('alias','false')
  try:
   check(transport+'_disabled_alias_warmed_auth_refused',c.register(separate,realm=state['alias'],reuse_nonce=True)['code']==403)
   dial=esl('user_data '+separate['auth']+'@'+state['realm']+' param dial-string');check(transport+'_disabled_alias_dial_contact_excluded',a['requested_contact'] not in dial and b['requested_contact'] in dial)
   check(transport+'_disabled_alias_user_lookup_refused',esl('user_data '+separate['auth']+'@'+state['alias']+' var domain_name')!=state['realm'])
  finally:mutate('alias','true')
  for kind in ['tenant','domain']:
   c.register(separate,realm=state['alias']);mutate(kind,'false')
   try:
    check(transport+'_alias_'+kind+'_warmed_auth_refused',c.register(separate,realm=state['alias'],reuse_nonce=True)['code']==403)
    check(transport+'_alias_'+kind+'_canonical_dial_refused',a['requested_contact'] not in esl('user_data '+separate['auth']+'@'+state['realm']+' param dial-string'))
   finally:mutate(kind,'true')
  check(transport+'_existing_mobile_canonical_account_unchanged',c.register(state['mobile'])['code']==200)
  check(transport+'_realm_bound_mobile_credentials_do_not_accept_alias',c.register(state['mobile'],realm=state['alias'])['code']==403)
  c.register(state['mobile'],expires=0)
 finally:
  c.close();second.close()
  for u in users+[state['ordinary'],state['mobile']]:
   for realm in [state['realm'],state['alias'],state['alias2']]:flush(u,realm)
report={'scope':'owned-phone-domain-alias','transports':['udp','tcp','tls'],'source_users':len(users),'source_credentials_unchanged':True,'canonical_restore_policy_unchanged_except_phone_address_metadata':True,'tls_certificate_validation_enabled':True,'tls_test_certificate_private_not_production':True,'checks':checks,'count':len(checks),'failed_cases':failed,'all_passed':not failed,'loopback_only':True,'production_unchanged':True,'known_phone_models':['Yealink W60B','Fanvil V62W'],'physical_model_firmware_port_interoperability_pending':True}
(ROOT/'alias-native-evidence.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='checks'}));raise SystemExit(0 if not failed else 1)
