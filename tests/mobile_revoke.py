#!/usr/bin/env python3
"""Exercise the native revoker's generated SQL against isolated registration rows."""
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'app/pbx_setup/resources/switch/scripts/app/pbx_setup/mobile_revoke.lua'
HARNESS = r'''
package.path=arg[1]..'/app/switch/resources/scripts/?.lua;'..package.path
local json=require 'resources.functions.lunajson'
local mode=arg[3]
local report={dsns={},queries={},releases=0,result=''}
package.preload['resources.functions.database']=function()
    return {new=function(dsn)
        local system=dsn=='system'
        return {
            release=function() report.releases=report.releases+1 end,
            query=function(self,sql,params,callback)
                if system then
                    if sql:find('v_pbx_mobile_devices',1,true) then
                        assert(sql:find('revoked_at is not null',1,true))
                        assert(params.id=='00000000-0000-4000-8000-000000000001')
                        if mode~='absent' then callback({sip_username='owm-'..string.rep('a',32),domain_name='tenant.example'}) end
                    elseif mode=='custom' then
                        callback({name='dbname',value='custom_'..params.profile})
                    elseif mode=='odbc' then
                        callback({name='odbc-dsn',value='fixture:readonly:test'})
                        callback({name='dbname',value='must_not_override_odbc'})
                    end
                else
                    report.queries[#report.queries+1]={sql=sql,params=params,dsn=dsn}
                    return mode~='failure'
                end
                return true
            end
        }
    end}
end
freeswitch={API=function()return {execute=function(_,command,value)
    assert(command=='sofia' and value:match('^status profile internal'))
    return mode=='stopped' and 'Invalid Profile!' or 'SIP-IP 127.0.0.1'
end}end,Dbh=function(dsn)report.dsns[#report.dsns+1]=dsn;return dsn end}
argv={mode=='invalid' and '../other' or '00000000-0000-4000-8000-000000000001'}
stream={write=function(_,text)report.result=text end}
assert(loadfile(arg[2]))()
print(json.encode(report))
'''


@unittest.skipUnless(shutil.which('lua'), 'Lua interpreter required')
class MobileRevoke(unittest.TestCase):
    def run_helper(self, mode='normal'):
        with tempfile.TemporaryDirectory() as directory:
            harness = Path(directory) / 'run.lua'
            harness.write_text(HARNESS)
            return json.loads(subprocess.check_output(
                ['lua', str(harness), str(ROOT), str(HELPER), mode], text=True))

    def test_scoped_contact_removal_retains_native_cleanup_fields(self):
        result = self.run_helper()
        self.assertTrue(result['result'].startswith('+OK'))
        self.assertEqual(result['dsns'], ['sofia_reg_internal', 'sofia_reg_internal-ipv6'])
        self.assertEqual(result['releases'], 3)
        for query in result['queries']:
            db = sqlite3.connect(':memory:')
            db.execute('create table sip_registrations(sip_username,sip_realm,sip_user,contact,expires,call_id,network_ip,network_port)')
            device = 'owm-' + 'a' * 32
            # Includes XML metacharacters, quoting and an address-shaped Call-ID
            # that the native flush command would also interpret as another user.
            call_ids = ['legal!&\'"id@host', '1001@tenant.example']
            rows = [(device, 'tenant.example', '1000', 'sip:phone', 1000, call_id, '192.0.2.1', 5061) for call_id in call_ids]
            rows += [('original-phone', 'tenant.example', '1000', 'sip:desk', 1000, 'desk@host', '192.0.2.2', 5060),
                     (device, 'other.example', '1000', 'sip:other', 1000, 'other@host', '192.0.2.3', 5060),
                     ('second-phone', 'tenant.example', '1001', 'sip:second', 1000, 'second@host', '192.0.2.4', 5060)]
            db.executemany('insert into sip_registrations values(?,?,?,?,?,?,?,?)', rows)
            db.execute(query['sql'], query['params'])
            actual = db.execute('select * from sip_registrations order by rowid').fetchall()
            expected = [row[:3] + ('', 1) + row[5:] for row in rows[:2]] + rows[2:]
            self.assertEqual(actual, expected)
            db.close()

    def test_missing_or_stopped_phone_has_no_native_mutation(self):
        for mode in ['absent', 'stopped']:
            with self.subTest(mode=mode):
                result = self.run_helper(mode)
                self.assertTrue(result['result'].startswith('+OK'))
                self.assertFalse(result['queries'])
                self.assertFalse(result['dsns'])

    def test_invalid_identifier_never_connects(self):
        result = self.run_helper('invalid')
        self.assertTrue(result['result'].startswith('-ERR'))
        self.assertEqual(result['releases'], 0)

    def test_native_failure_is_reported_and_handles_released(self):
        result = self.run_helper('failure')
        self.assertTrue(result['result'].startswith('-ERR'))
        self.assertEqual(result['releases'], 2)

    def test_profile_database_override_and_odbc_precedence(self):
        self.assertEqual(self.run_helper('custom')['dsns'], ['custom_internal', 'custom_internal-ipv6'])
        self.assertEqual(self.run_helper('odbc')['dsns'], ['fixture:readonly:test'] * 2)


if __name__ == '__main__':
    unittest.main()
