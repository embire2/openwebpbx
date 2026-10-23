"""Actual global SMTP POST/notice source; native SMTP transport stays separate."""
import argparse
import ast
from html import escape
from html.parser import HTMLParser
import json
import os
from pathlib import Path, PureWindowsPath
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
source=ROOT/'tests/windows-native-acceptance.py'
tree=ast.parse(source.read_text())
functions=[node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=='smtp_connection_check_passed']
assert len(functions)==1
scope={'HTMLParser':HTMLParser}
exec(compile(ast.Module(body=functions,type_ignores=[]),str(source),'exec'),scope)
accepted=scope['smtp_connection_check_passed']
PHP_EXECUTABLE=None
WINDOWS_PHP=PureWindowsPath(r'C:\OpenWebPBX\php\php.exe')
SELECTORS=('SMTPNoticeControls.test_actual_dom_success_and_refusals',
           'SMTPNoticeControls.test_actual_php_post_notice_and_refusals')


def installed_windows_php(value):
    return isinstance(value,str) and PureWindowsPath(value)==WINDOWS_PHP


def required_php(value):
    if not isinstance(value,str) or not value:
        raise ValueError('The PHP POST controls require --php-executable; no ambient PHP or skipped result is accepted.')
    path=Path(value)
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        raise ValueError('An explicit absolute ordinary PHP executable is required.')
    if os.name=='nt' and not installed_windows_php(value):
        raise ValueError('Windows POST controls require the manifest-verified installed PHP executable.')
    return str(path)


def parse_cli(arguments):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--php-executable',help='Explicit PHP executable; on Windows only the manifest-verified installed C:\\OpenWebPBX\\php\\php.exe is accepted.')
    parser.add_argument('selectors',nargs='*',metavar='TEST')
    parsed=parser.parse_args(arguments)
    if any(value not in SELECTORS for value in parsed.selectors):
        parser.error('Select only the explicit DOM or PHP POST unittest method.')
    return parsed


class SMTPNoticeControls(unittest.TestCase):
    def test_actual_dom_success_and_refusals(self):
        notice='SMTP connection and From address accepted. No email was sent; recipient acceptance and inbox delivery are still untested.'
        good='<div class="mail-message" role="status">'+escape(notice)+'</div>'
        self.assertTrue(accepted(good))
        self.assertTrue(accepted('<div role="status" class="other mail-message">SMTP connection and From address accepted.\n<span>No email was sent</span>; delivery remains untested.</div>'))
        for body in [None,False,{},notice,'<p>'+notice+'</p>','<script>'+notice+'</script>',good+good,
                     good.replace('role="status"','role="alert"'),good.replace('mail-message','mail-message error'),
                     good.replace('mail-message','other'),good.replace('No email was sent','Email was sent'),
                     good.replace('From address accepted.','From address rejected.'),good.replace('</div>',''),
                     good+'<div class="mail-message" role="status">Another status.</div>',
                     '<div class="mail-message" role="status"><script>'+notice+'</script></div>',
                     '<div class="mail-message" role="status"><style>'+notice+'</style></div>',
                     '<div class="mail-message" role="status">SMTP connection succeeded. No email was sent.</div>',
                     good+'<div class="mail-message error" role="alert">Wrong server or credentials.</div>',
                     '<div class="mail-message" role="status">Outgoing mail settings saved for all tenants.</div>','x'*(4*1024*1024+1)]:
            with self.subTest(body=str(body)[:40]):self.assertFalse(accepted(body))

    def test_actual_php_post_notice_and_refusals(self):
        executable=required_php(PHP_EXECUTABLE)
        version=subprocess.run([executable,'-n','-r','echo PHP_VERSION;'],capture_output=True,text=True,timeout=5)
        self.assertEqual(version.returncode,0,version.stderr);self.assertRegex(version.stdout,r'^\d+\.\d+\.\d+(?:[-+].*)?$')
        if os.name=='nt':self.assertEqual(version.stdout,'8.4.27')
        print(json.dumps({'actual_php_cli_version':version.stdout,'scope':'checkout POST prelude; explicit token/mail transport doubles','native_windows_or_smtp_transport_qualified':False}))
        php=r'''<?php
$scenario=json_decode($argv[2],true,512,JSON_THROW_ON_ERROR);$output=$argv[3];$calls=0;$saves=0;
class outgoing_mail {
 function canManage(){return true;}
 function save($values){$GLOBALS['saves']++;}
 function checkConnection(){
  $GLOBALS['calls']++;
  if(($GLOBALS['scenario']['transport']??'')==='throw')throw new RuntimeException('Private fictional transport refusal.');
  return ($GLOBALS['scenario']['transport']??'')==='accepted';
 }
}
class token {function validate($key){return $GLOBALS['scenario']['csrf']??true;}}
$_SESSION=[];$_SERVER=['REQUEST_METHOD'=>$scenario['method']??'POST'];$_POST=['action'=>$scenario['action']??'check'];
register_shutdown_function(function()use($output){file_put_contents($output,json_encode(['notice'=>$_SESSION['smtp_notice']??'','error'=>$GLOBALS['error']??'','calls'=>$GLOBALS['calls'],'saves'=>$GLOBALS['saves']]));});
$source=file_get_contents($argv[1]);$start=strpos($source,'$mailSettings = new outgoing_mail;');$end=strpos($source,'$saved = $mailSettings->view();');
if($start===false||$end===false||$end<=$start)throw new RuntimeException('The actual SMTP POST boundary is absent.');
eval(substr($source,$start,$end-$start));
'''
        scenarios=[({'transport':'accepted'},True,1,0),({'transport':'refused'},False,1,0),({'transport':'throw'},False,1,0),
                   ({'transport':'accepted','csrf':False},False,0,0),({'action':'other'},False,0,0),({'action':'save'},False,0,1),({'method':'GET'},False,0,0)]
        with tempfile.TemporaryDirectory(prefix='openweb-smtp-notice-') as directory:
            root=Path(directory);script=root/'post.php';script.write_text(php)
            for i,(scenario,success,calls,saves) in enumerate(scenarios):
                output=root/(str(i)+'.json')
                result=subprocess.run([executable,'-n',str(script),str(ROOT/'app/smtp_settings/index.php'),json.dumps(scenario),str(output)],capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,0,result.stderr);self.assertFalse(result.stderr)
                row=json.loads(output.read_text());self.assertEqual(row['calls'],calls);self.assertEqual(row['saves'],saves)
                body='<div class="mail-message" role="status">'+escape(row['notice'])+'</div>' if row['notice'] else ''
                if row['error']:body+='<div class="mail-message error" role="alert">'+escape(row['error'])+'</div>'
                self.assertIs(accepted(body),success)
                if success:
                    self.assertFalse(row['error']);self.assertIn('From address accepted.',row['notice']);self.assertIn('No email was sent',row['notice'])
                    self.assertNotIn('SMTP connection succeeded. No email was sent.',body)


if __name__=='__main__':
    arguments=parse_cli(sys.argv[1:])
    PHP_EXECUTABLE=arguments.php_executable
    unittest.main(argv=[sys.argv[0],*arguments.selectors])
