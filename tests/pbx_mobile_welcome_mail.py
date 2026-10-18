"""Real loopback SMTP/MIME proof; never connects to a public relay."""
from pathlib import Path
from email.parser import BytesParser
from email.policy import default
import hashlib,json,socketserver,threading,subprocess,sys,os
from smtp_transport_integration import SMTPFixture
class WelcomeSMTP(SMTPFixture):
 def reply(self,text):
  # The first message succeeds; the next real dispatch receives a sender refusal.
  if text=='250 Sender accepted' and len(self.server.connections)>=1:text='550 Fixture sender refused'
  super().reply(text)

if __name__=='__main__':
 os.umask(0o077);out=Path(sys.argv[1]);out.mkdir(mode=0o700,exist_ok=False)
 with socketserver.ThreadingTCPServer(('127.0.0.1',0),WelcomeSMTP)as fixture:
  fixture.deliveries=[];fixture.connections=[];fixture.envelopes=[];fixture.record_lock=threading.Lock();fixture.daemon_threads=True
  worker=threading.Thread(target=fixture.serve_forever,daemon=True);worker.start()
  try:
   subprocess.run(['php',str(Path(__file__).with_suffix('.php')),str(fixture.server_address[1]),str(out)],cwd=Path(__file__).resolve().parents[1],check=True,timeout=120)
   assert len(fixture.deliveries)==1,'Concurrent/obsolete welcome was delivered more than once'
   message=BytesParser(policy=default).parsebytes(fixture.deliveries[0][1]);(out/'captured.private.eml').write_bytes(fixture.deliveries[0][1])
   expected=json.loads((out/'expected.private.json').read_text());parts=list(message.walk());png=[p for p in parts if p.get_content_type()=='image/png'];config=[p for p in parts if p.get_content_type()=='application/vnd.openwebpbx.config+json'];html=[p for p in parts if p.get_content_type()=='text/html']
   assert len(png)==len(config)==len(html)==1
   assert png[0]['Content-Disposition'].startswith('inline')and str(png[0]['Content-ID']).strip('<>')in html[0].get_content()
   assert hashlib.sha256(png[0].get_payload(decode=True)).hexdigest()==expected['png_sha256']
   assert json.loads(config[0].get_payload(decode=True))==expected['payload']
   assert config[0].get_filename()=='OpenWebPBX-100.openwebpbx'and'password'not in expected['payload']
   assert fixture.connections==[(False,0),(False,0)]and fixture.envelopes==['MAIL FROM:<welcome@example.invalid>']*2
   safe={'one_actual_delivery':True,'two_concurrent_dispatchers':True,'inline_png_content_id_matches':True,'png_exact':True,'setup_json_exact':True,'one_use_password_free_payload':True,'global_sender_no_auth':True,'real_550_marks_failed_and_ui_reports_failure':True,'no_external_mail':True}
   (out/'mime.safe.json').write_text(json.dumps(safe,indent=2)+'\n');print('PASS: actual SMTP MIME/CID/PNG/setup attachment, concurrent dispatcher and obsolete invitation suppression')
  finally:fixture.shutdown();worker.join(timeout=2)
