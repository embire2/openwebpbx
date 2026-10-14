"""Disposable loopback native registrar quotas; no product database or services."""
import argparse,importlib.util,json,re,socket,sys,time
from pathlib import Path

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module);return module

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--input',required=True);args=parser.parse_args()
    path=Path(args.input);state=json.loads(path.read_text(encoding='utf-8-sig'))
    assert state['schema']==1 and state['scope']=='fictional-loopback-registration-limits'
    assert state['qualification'] is True
    assert state['sip_port']==19264 and state['esl_port']==18224 and re.fullmatch(r'native-limit-[a-f0-9]{24}\.invalid',state['realm'])
    root=path.parent;realm=state['realm'];profile='private_limits';rows=[];peers=[];cleanup=[]
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
        for record in state['users']:
            key=record['auth']+'@'+realm
            allowed|=command in ['sofia_contact */'+key,'sofia profile private_limits flush_inbound_reg '+key]
        assert allowed;sock.sendall(('api '+command+'\n\n').encode());return frame()[1]
    def registered(record):
        result=api('sofia_contact */'+record['auth']+'@'+realm).strip()
        (root/('contact-'+record['number']+'.private.txt')).write_text(result)
        return not result.startswith('error/') and result!=''
    class Phone(source.SourcePhone):
        def __init__(self,record,label):self.trace=[];self.label=label;super().__init__(record,realm,'127.0.0.1')
        def packet(self,*args,**kwargs):
            data=super().packet(*args,**kwargs)
            if args and args[0]=='REGISTER':self.trace.append(data);assert len(self.trace)<=20
            return data
    def peer(index,label):
        phone=Phone(state['users'][index],label);peers.append((phone,state['users'][index]));return phone
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
        sock.close()
        by_case={row['case']:row for row in rows}
        report={'schema':1,'scope':'fictional-loopback-registration-limits','loopback_only':True,'product_database_or_services_accessed':False,'private_sqlite_only':True,
                'cases':rows,'contacts_after_cleanup':sum(not value for value in cleanup),
                'individual_tuples_authenticated':all(by_case.get('individual-'+str(i),{}).get('code')==200 for i in range(2)),
                'both_orders_accepted':all(by_case.get('simultaneous-'+order+'-'+str(i),{}).get('code')==200 for order in ['0-1','1-0'] for i in range(2)),
                'same_account_second_contact_refused':all(by_case.get('simultaneous-'+order+'-extra-contact',{}).get('code')==403 for order in ['0-1','1-0']),
                'reverse_order_both_accepted':all(by_case.get('simultaneous-1-0-'+str(i),{}).get('code')==200 for i in range(2))}
        if error:report['error_type']=error
        (root/'registration-report.json').write_text(json.dumps(report,indent=2))
        print(json.dumps(report))
    if error or not all(cleanup) or not report['both_orders_accepted'] or not report['same_account_second_contact_refused']:return 1
    return 0
if __name__=='__main__':sys.exit(main())
