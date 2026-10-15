"""Disposable loopback native registrar quotas; no product database or services."""
import argparse,importlib.util,json,math,re,secrets,socket,sqlite3,sys,time
from pathlib import Path

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module);return module

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--input',required=True);args=parser.parse_args()
    path=Path(args.input);state=json.loads(path.read_text(encoding='utf-8-sig'))
    assert state['schema']==1 and state['scope']=='fictional-loopback-registration-limits'
    assert state['qualification'] is True
    assert state['sip_port']==19264 and state['esl_port']==18224 and re.fullmatch(r'native-limit-[a-f0-9]{24}\.invalid',state['realm'])
    assert state['collision_realm']=='native-limit-collision-'+state['realm'][len('native-limit-'):]
    root=path.parent;realm=state['realm'];profile='private_limits';rows=[];peers=[];cleanup=[]
    realms=(realm,state['collision_realm'])
    boundary_gate={'passed':False,'cycles_required':24,'cycles_completed':0,'attempts':0,'samples_checked':0,'observation_delays_ms':[0,50,250],'same_call_id_and_increasing_cseq':False,'both_accounts_present_each_sample':False,'sqlite_readonly':True,'sql_writes_or_queue_pauses':False}
    isolation_gate={'passed':False,'cases_required':3,'cases_completed':0,'native_mode':'call-id','native_contact_mode_tested':False,'sqlite_readonly':True,'sql_writes_or_queue_pauses':False,'cases':[]}
    load('sip_trunk_live',root/'sip_trunk_live.py');source=load('private_source_phone',root/'pbx_v20_restore_native.py')
    sock=socket.create_connection(('127.0.0.1',18224),timeout=5);sock.settimeout(5);buffer=bytearray()
    def frame():
        while True:
            split=buffer.find(b'\n\n')
            if split>=0:
                headers=dict(x.split(': ',1) for x in bytes(buffer[:split]).decode().splitlines() if ': ' in x);size=int(headers.get('Content-Length','0'));assert 0<=size<=1048576
                if len(buffer)>=split+2+size:
                    body=bytes(buffer[split+2:split+2+size]).decode();del buffer[:split+2+size];return headers,body
            data=sock.recv(65536);assert data;buffer.extend(data)
    assert frame()[0].get('Content-Type')=='auth/request'
    sock.sendall(('auth '+state['esl_password']+'\n\n').encode());assert frame()[0].get('Reply-Text')=='+OK accepted'
    def api(command):
        allowed=command=='sofia status profile private_limits'
        for owned_realm in realms:
            for record in state['users']:
                key=record['auth']+'@'+owned_realm
                allowed|=command=='sofia_contact */'+key
                if owned_realm==realm:allowed|=command=='sofia profile private_limits flush_inbound_reg '+key
        assert allowed;sock.sendall(('api '+command+'\n\n').encode());return frame()[1]
    def registered(record):
        result=api('sofia_contact */'+record['auth']+'@'+realm).strip()
        (root/('contact-'+record['number']+'.private.txt')).write_text(result)
        return not result.startswith('error/') and result!=''
    class Phone(source.SourcePhone):
        def __init__(self,record,label,max_packets=20):self.trace=[];self.label=label;self.max_packets=max_packets;self.receiver_failure=None;super().__init__(record,realm,'127.0.0.1')
        def run(self):
            try:super().run()
            except BaseException as error:self.receiver_failure=type(error).__name__;raise
        def packet(self,*args,**kwargs):
            data=super().packet(*args,**kwargs)
            if args and args[0]=='REGISTER':
                if hasattr(self,'fixed_contact'):data=re.sub(rb'(?m)^Contact: [^\r\n]*',b'Contact: <'+self.fixed_contact.encode()+b'>',data)
                self.trace.append(data);assert len(self.trace)<=self.max_packets
                if self.label.startswith('boundary-'):
                    with (root/(self.label+'-registers.private.bin')).open('ab') as stream:stream.write(data+b'\n\n')
            return data
    def peer(index,label,max_packets=20):
        phone=Phone(state['users'][index],label,max_packets);peers.append((phone,state['users'][index]));return phone
    def register(phone,index,label,expires=120):
        result=phone.register(('127.0.0.1',19264),expires=expires)
        code=int(result['code']);assert 200<=code<=699
        (root/(label+'.response.private.txt')).write_text(result.get('text',''))
        (root/(label+'.requests.private.bin')).write_bytes(b'\n\n'.join(phone.trace))
        row={'case':label,'peer':index,'code':code,'digest_challenge_count':int(result['digest_challenge_count']),'canonical_contact_present':registered(state['users'][index])}
        rows.append(row);return row
    def unregister(phone,index,label):
        row=register(phone,index,label,0)
        assert row['code']==200 and not row['canonical_contact_present'],'Exact owned unregister failed'
    def boundary_refresh():
        # Genuine SIP renewals exercise the SQL worker's normal batching window.
        # Reads use the clone's actual SQLite database and exact owned API keys.
        database=(root/'db/sofia_reg_private_limits.db').resolve()
        assert database.is_file() and not database.is_symlink()
        active=[peer(i,'boundary-'+str(i),600) for i in range(2)]
        previous={};private=root/'boundary-refresh.private.jsonl'
        def renew(index,label):
            phone=active[index];started=time.time();result=phone.register(('127.0.0.1',19264));completed=time.time()
            assert result['code']==200 and phone.receiver_failure is None,'Boundary refresh SIP/receiver failed'
            old=previous.get(index)
            if old:assert result['callid']==old['callid'] and result['seq']>old['seq'],'Boundary refresh changed its Call-ID/CSeq'
            previous[index]=result
            with private.open('a') as stream:stream.write(json.dumps({'stage':label,'peer':index,'started_epoch':started,'completed_epoch':completed,'call_id':result['callid'],'cseq':result['seq'],'response':result.get('text','')})+'\n')
            return dict(result,completed_epoch=completed)
        def observe(stage,reference,delay):
            with sqlite3.connect(database.as_uri()+'?mode=ro',uri=True,timeout=.2) as db:
                db.execute('PRAGMA query_only=ON')
                actual=db.execute('select call_id,sip_user,contact,expires,ping_status,ping_count from sip_registrations where profile_name=? and sip_host=? and sip_user in (?,?) order by sip_user,call_id',(profile,realm,state['users'][0]['auth'],state['users'][1]['auth'])).fetchall()
            contacts={i:api('sofia_contact */'+state['users'][i]['auth']+'@'+realm).strip() for i in range(2)}
            row={'stage':stage,'delay_requested_ms':delay,'observed_epoch':time.time(),'actual_after_register_ms':round((time.time()-reference['completed_epoch'])*1000,3),'sql_rows':actual,'api_contacts':contacts}
            with private.open('a') as stream:stream.write(json.dumps(row)+'\n')
            for i in range(2):
                owned=[r for r in actual if r[0]==previous[i]['callid'] and r[1]==state['users'][i]['auth']]
                uri='sip:'+active[i].aor+'@127.0.0.1:'+str(active[i].port)
                assert len(owned)==1 and uri in owned[0][2],'Boundary refresh lost/duplicated an exact owned SQLite row'
                assert contacts[i] and not contacts[i].startswith('error/') and uri in contacts[i],'Boundary refresh lost an exact owned API contact'
                assert active[i].receiver_failure is None,'Boundary peer receiver stopped'
            return {i:next(r[3] for r in actual if r[0]==previous[i]['callid'] and r[1]==state['users'][i]['auth']) for i in range(2)}
        warmup=None
        for i in range(2):warmup=renew(i,'warmup')
        observe('warmup',warmup,0)
        while boundary_gate['cycles_completed']<24 and boundary_gate['attempts']<48:
            boundary_gate['attempts']+=1;index=boundary_gate['attempts']%2
            target=math.floor(time.time())+.94
            if target<=time.time():target+=1
            while time.time()<target:time.sleep(min(.005,max(.0002,target-time.time())))
            initial=renew(index,'initial');before=observe('initial',initial,0)
            for pressure in range(5):
                if time.time()>=math.floor(initial['completed_epoch'])+1+.015:break
                renew(1-index,'legitimate-other-account-pressure')
            target=math.floor(initial['completed_epoch'])+1+.02
            while time.time()<target:time.sleep(min(.002,max(.0002,target-time.time())))
            refreshed=renew(index,'refresh');after=None
            for delay in (0,50,250):
                wanted=refreshed['completed_epoch']+delay/1000
                while time.time()<wanted:time.sleep(min(.002,max(.0002,wanted-time.time())))
                after=observe('refreshed',refreshed,delay);boundary_gate['samples_checked']+=2
            # Count only actual native expiry advances across one UTC second;
            # timing misses are observed strictly but do not manufacture cycles.
            if (math.floor(refreshed['completed_epoch'])==math.floor(initial['completed_epoch'])+1
                    and 0<refreshed['completed_epoch']-initial['completed_epoch']<.195
                    and after[index]==before[index]+1):
                boundary_gate['cycles_completed']+=1
        for i,phone in enumerate(active):
            (root/('boundary-peer-'+str(i)+'-registers.private.bin')).write_bytes(b'\n\n'.join(phone.trace))
        assert boundary_gate['cycles_completed']==24,'Twenty-four actual second-boundary expiry advances were not observed'
        for i in reversed(range(2)):
            unregister(active[i],i,'boundary-'+str(i)+'-unregister')
            if i==1:assert registered(state['users'][0]),'Boundary exact unregister removed another account'
            active[i].close();peers.remove((active[i],state['users'][i]))
        boundary_gate.update(passed=True,same_call_id_and_increasing_cseq=True,both_accounts_present_each_sample=True)
    def shared_binding_isolation():
        # One genuine UA/socket owns two AORs. Its Contact and Call-ID are
        # deliberately identical; only the authenticated user/realm changes.
        # This profile exercises Call-ID mode; actual-C/SQLite covers Contact mode.
        database=(root/'db/sofia_reg_private_limits.db').resolve()
        assert database.is_file() and not database.is_symlink()
        cases=((1,realm,'different-user-same-realm'),(0,realms[1],'same-user-different-realm'),(1,realms[1],'different-user-different-realm'))
        for foreign_index,foreign_realm,label in cases:
            phone=Phone(state['users'][0],'shared-'+label,40)
            phone.fixed_contact='sip:9001@127.0.0.1:'+str(phone.port)
            shared_id=secrets.token_hex(12)+'@shared-native-fixture';tag=secrets.token_hex(5)
            phone.registration_transaction={'cid':shared_id,'seq':0,'from':''}
            owner=(0,realm);foreign=(foreign_index,foreign_realm);last_seq=0
            private=root/('shared-'+label+'.private.jsonl');case={'case':label,'passed':False,'samples_checked':0,'exact_cleanup':False};isolation_gate['cases'].append(case)
            def select(identity):
                index,owned_realm=identity;record=state['users'][index]
                phone.aor=record['number'];phone.auth_user=record['auth'];phone.password=record['password'];phone.realm=owned_realm
                phone.registration_transaction['from']='<sip:'+phone.aor+'@'+owned_realm+'>;tag='+tag
            def send(identity,expires,stage):
                nonlocal last_seq
                select(identity);result=phone.register(('127.0.0.1',19264),expires=expires)
                with private.open('a') as stream:stream.write(json.dumps({'stage':stage,'code':result['code'],'cseq':result['seq'],'response':result.get('text','')})+'\n')
                assert result['code']==200 and phone.receiver_failure is None,'Shared-binding SIP/receiver failed'
                assert result['callid']==shared_id and result['seq']>last_seq,'Shared-binding Call-ID/CSeq changed'
                last_seq=result['seq']
                for packet in phone.trace:
                    assert re.search(rb'(?m)^Call-ID: ([^\r\n]+)',packet)[1]==shared_id.encode()
                    assert re.search(rb'(?m)^Contact: ([^\r\n]+)',packet)[1]==b'<'+phone.fixed_contact.encode()+b'>'
                return time.monotonic()
            def read(identity):
                index,owned_realm=identity;auth=state['users'][index]['auth']
                with sqlite3.connect(database.as_uri()+'?mode=ro',uri=True,timeout=.2) as db:
                    db.execute('PRAGMA query_only=ON')
                    actual=db.execute('select sip_user,sip_host,call_id,contact,expires from sip_registrations where profile_name=? and sip_user=? and sip_host=? order by call_id,contact',(profile,auth,owned_realm)).fetchall()
                contact=api('sofia_contact */'+auth+'@'+owned_realm).strip()
                with private.open('a') as stream:stream.write(json.dumps({'read_identity':[index,realms.index(owned_realm)],'sql_rows':actual,'api_contact':contact})+'\n')
                return actual,contact
            def present(identity):
                actual,contact=read(identity)
                assert len(actual)==1 and actual[0][2]==shared_id and phone.fixed_contact in actual[0][3],'Shared-binding exact SQLite row missing'
                assert contact and not contact.startswith('error/') and phone.fixed_contact in contact,'Shared-binding exact API contact missing'
                return actual[0]
            def absent(identity):
                actual,contact=read(identity)
                assert not actual and (not contact or contact.startswith('error/')),'Shared-binding exact unregister left a contact'
            def observe(stage,completed,owner_present):
                for delay in (0,50,250):
                    wanted=completed+delay/1000
                    while time.monotonic()<wanted:time.sleep(min(.002,max(.0002,wanted-time.monotonic())))
                    preserved=present(foreign)
                    assert preserved==foreign_row,'Shared-binding operation changed the foreign row'
                    if owner_present:
                        own=present(owner)
                        assert own[2]==preserved[2] and own[3]==preserved[3],'Actual Call-ID/Contact collision was not identical'
                        assert own[4]!=preserved[4],'Actual colliding expiries did not differ'
                        assert (own[0]!=preserved[0])==(foreign_index!=0),'Actual canonical user collision case differed'
                        assert (own[1]!=preserved[1])==(foreign_realm!=realm),'Actual canonical realm collision case differed'
                    else:absent(owner);own=None
                    assert phone.receiver_failure is None,'Shared-binding receiver stopped'
                    with private.open('a') as stream:stream.write(json.dumps({'stage':stage,'delay_ms':delay,'actual_delay_ms':round((time.monotonic()-completed)*1000,3),'foreign_sql_row':preserved,'owner_sql_row':own})+'\n')
                    case['samples_checked']+=1
            primary=None;cleanup_errors=[]
            try:
                send(foreign,180,'foreign-register');foreign_row=present(foreign)
                observe('owner-register',send(owner,120,'owner-register'),True)
                observe('owner-refresh',send(owner,120,'owner-refresh'),True)
                observe('owner-unregister',send(owner,0,'owner-unregister'),False)
                send(foreign,0,'foreign-unregister');absent(owner);absent(foreign)
            except BaseException as failure:primary=failure
            finally:
                # Exact SIP transactions only; no SQL/API flush or global cleanup.
                for identity in (owner,foreign):
                    try:
                        actual,_=read(identity)
                        if actual:send(identity,0,'cleanup-unregister')
                        absent(identity)
                    except BaseException as failure:cleanup_errors.append(type(failure).__name__)
                (root/('shared-'+label+'.requests.private.bin')).write_bytes(b'\n\n'.join(phone.trace))
                phone.close()
                case['exact_cleanup']=not cleanup_errors
                if cleanup_errors:case['cleanup_error_types']=cleanup_errors
            if primary:raise primary
            assert not cleanup_errors,'Shared-binding exact cleanup failed'
            case.update(passed=True,identical_call_id_and_contact=True,different_expiries=True,foreign_preserved_after_register_refresh_unregister=True)
            isolation_gate['cases_completed']+=1
        isolation_gate['passed']=isolation_gate['cases_completed']==3
    error=None
    try:
        assert api('sofia status profile private_limits').find('127.0.0.1')>=0
        invalid=peer(0,'wrong-password')
        denied=invalid.register(('127.0.0.1',19264),password='wrong-fictional-secret')
        assert denied['code'] in (401,403) and not registered(state['users'][0]),'Wrong password authenticated'
        rows.append({'case':'wrong-password','code':int(denied['code']),'canonical_contact_present':False})
        invalid.close();peers.remove((invalid,state['users'][0]))
        for index in range(2):
            phone=peer(index,'individual-'+str(index))
            row=register(phone,index,'individual-'+str(index))
            assert row['code']==200 and row['canonical_contact_present'],'Distinct fictional tuple did not authenticate individually'
            unregister(phone,index,'individual-'+str(index)+'-unregister');phone.close();peers.remove((phone,state['users'][index]))
        for order in [(0,1),(1,0)]:
            label='simultaneous-'+str(order[0])+'-'+str(order[1]);active=[]
            for index in order:
                phone=peer(index,label+'-'+str(index));row=register(phone,index,label+'-'+str(index));active.append((phone,index,row['code']))
                assert row['code']==200 and row['canonical_contact_present'],'Distinct simultaneous tuple failed'
            first=active[0][0];first_index=order[0]
            refresh=register(first,first_index,label+'-refresh')
            assert refresh['code']==200 and refresh['canonical_contact_present'],'Own Call-ID refresh exceeded its quota'
            extra=peer(first_index,label+'-extra-contact')
            refused=register(extra,first_index,label+'-extra-contact')
            assert refused['code']==403 and refused['canonical_contact_present'],'Same-account second contact was not refused at limit one'
            extra.close();peers.remove((extra,state['users'][first_index]))
            for phone,index,code in reversed(active):
                if code==200:unregister(phone,index,label+'-'+str(index)+'-unregister')
                if index==order[1]:assert registered(state['users'][order[0]]),'Exact unregister removed the other canonical account'
                phone.close();peers.remove((phone,state['users'][index]))
        boundary_refresh()
        shared_binding_isolation()
    except BaseException as failure:error=type(failure).__name__
    finally:
        for phone,record in peers:
            try:phone.register(('127.0.0.1',19264),expires=0)
            except BaseException:pass
            phone.close()
        for record in state['users']:
            present=registered(record)
            if present:api('sofia profile private_limits flush_inbound_reg '+record['auth']+'@'+realm)
            cleanup.append(not registered(record))
        for record in state['users']:
            result=api('sofia_contact */'+record['auth']+'@'+realms[1]).strip()
            cleanup.append(not result or result.startswith('error/'))
        sock.close()
        by_case={row['case']:row for row in rows}
        report={'schema':1,'scope':'fictional-loopback-registration-limits','loopback_only':True,'product_database_or_services_accessed':False,'private_sqlite_only':True,
                'cases':rows,'boundary_refresh':boundary_gate,'shared_binding_isolation':isolation_gate,'contacts_after_cleanup':sum(not value for value in cleanup),
                'individual_tuples_authenticated':all(by_case.get('individual-'+str(i),{}).get('code')==200 for i in range(2)),
                'both_orders_accepted':all(by_case.get('simultaneous-'+order+'-'+str(i),{}).get('code')==200 for order in ['0-1','1-0'] for i in range(2)),
                'same_account_second_contact_refused':all(by_case.get('simultaneous-'+order+'-extra-contact',{}).get('code')==403 for order in ['0-1','1-0']),
                'reverse_order_both_accepted':all(by_case.get('simultaneous-1-0-'+str(i),{}).get('code')==200 for i in range(2))}
        if error:report['error_type']=error
        (root/'registration-report.json').write_text(json.dumps(report,indent=2))
        print(json.dumps(report))
    if error or not all(cleanup) or not boundary_gate['passed'] or not isolation_gate['passed'] or not report['both_orders_accepted'] or not report['same_account_second_contact_refused']:return 1
    return 0
if __name__=='__main__':sys.exit(main())
