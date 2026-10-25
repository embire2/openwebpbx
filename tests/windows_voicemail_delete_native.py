"""Required isolated Windows voicemail delivery/deletion proof; no external mail or calls."""
from email.parser import BytesParser
from email.policy import default
import hashlib
import json
import os
from pathlib import Path
import socketserver
import threading
import time

CASE = 'native_voicemail_attach_delete_smtp250_durable_purge'
FLAGS = ('actual_windows_native','actual_installed_mail_consumer','consumer_attribution_nonexclusive','consumer_finished_before_restore','actual_installed_lua_dbh',
         'actual_installed_atomic_helper','admin_attach_and_delete','owned_copy_of_native_recording',
         'snapshot_before_smtp250','mailbox_and_file_before_smtp250','no_cleanup_before_smtp250',
         'smtp250_released_after_checks','mailbox_and_file_deleted_after_smtp250',
         'snapshot_cleared_after_cleanup','one_loopback_message','wav_sha256_verified',
         'global_sender_and_ip_auth_verified','mode_and_smtp_restored','owned_job_and_handles_closed',
         'no_external_mail','no_calls_originated','original_recording_preserved')


def handler(base):
    class HeldAcceptance(base):
        def reply(self, text):
            if text == '250 Captured locally':
                self.server.awaiting250.set()
                if not self.server.release250.wait(10):
                    raise RuntimeError('The bounded SMTP acceptance barrier expired.')
                result = super().reply(text)
                self.server.acceptance_sent.set()
                return result
            return super().reply(text)
    return HeldAcceptance


def delivery(f, original, sink, runner, expected):
    finished=threading.Event();abort=threading.Event();results=[];failures=[];job_proofs=[]
    deadline=time.monotonic()+15
    def tick():
        try:
            for attempt in range(64):
                if abort.is_set():return
                directory=f.evidence/('delete-mail-job-'+str(attempt));directory.mkdir(mode=0o700)
                result=runner([original.WINPS,'-NoProfile','-NonInteractive','-File','C:/OpenWebPBX/tools/Install-MailQueue.ps1','-Tick'],directory,timeout=240)
                result.check_returncode();closed=json.loads((directory/'process.safe.json').read_text())
                assert all(closed[name] is True for name in ('created_suspended','assigned_before_resume','resumed','ordinary_exit','owned_processes_closed','handles_closed'))
                job_proofs.append(closed);outcome=original.smtp_tick_fields(result)['smtp_tick_outcome']
                if outcome not in ('deferred_maintenance','deferred_restore'):
                    assert outcome=='processed','The actual installed Tick did not report its configured queue result.'
                    results.append(result);return
                if time.monotonic()>=deadline:raise RuntimeError('Existing SMTP maintenance observation budget expired.')
                abort.wait(.25)
            raise RuntimeError('Existing SMTP deferral count bound expired.')
        except BaseException as error:failures.append(error)
        finally:finished.set()
    sender=threading.Thread(target=tick,daemon=True);closed_by=time.monotonic()+255;sender.start()
    try:
        while not sink.awaiting250.wait(.05):
            if failures:raise failures[0]
            # The ordinary scheduled consumer can own the queue while our
            # bounded Tick correctly finds no work. Observe either consumer.
            assert time.monotonic()<deadline,'The installed worker did not reach SMTP DATA within the original15s budget.'
        held=f.cli('voicemail-delete-status')
        assert held['message_exists'] and held['file_exists'] and held['file_exact'] and held['snapshot_exact'] and not held['snapshot_cleared'] and held['original_recording_preserved']
        assert held['queue_state'] in ('waiting','trying') and not sink.acceptance_sent.is_set()
        assert len(sink.deliveries)==1
        message=BytesParser(policy=default).parsebytes(sink.deliveries[0][1])
        attachments=[part.get_payload(decode=True) for part in message.walk() if part.get_content_disposition()=='attachment']
        assert len(attachments)==1 and attachments[0][:4]==b'RIFF' and attachments[0][8:12]==b'WAVE' and len(attachments[0])>4096
        assert hashlib.sha256(attachments[0]).hexdigest()==expected
        assert str(message['From'])=='Fictional Windows PBX <pbx@example.invalid>' and str(message['Reply-To'])=='Fictional Windows PBX <reply@example.invalid>'
        sink.release250.set()
        assert finished.wait(max(0,closed_by-time.monotonic())),'The bounded owned Windows mail job did not finish.'
        if failures:raise failures[0]
        assert len(results)==1 and job_proofs
        settles_by=time.monotonic()+15
        while True:
            after=f.cli('voicemail-delete-status','settled')
            if after['consumer_released'] and sink.connections and sink.acceptance_sent.is_set():break
            assert time.monotonic()<settles_by,'The ordinary installed consumer did not finish within the15s observation budget.'
            time.sleep(.1)
        assert after['queue_state']=='sent' and not after['message_exists'] and not after['file_exists'] and after['snapshot_cleared'] and not after['snapshot_exact'] and after['original_recording_preserved']
        assert len(sink.deliveries)==1 and sink.connections==[(False,0)] and sink.envelopes==['MAIL FROM:<pbx@example.invalid>']
        return {'state':'passed',**{name:True for name in FLAGS},'attachment_sha256':expected}
    finally:
        # Always release SMTP before joining the owned Job or touching config.
        sink.release250.set();abort.set()
        if not finished.wait(max(0,closed_by-time.monotonic())):raise RuntimeError('The owned mail job did not close before cleanup.')
        sender.join(1)
        if sender.is_alive():raise RuntimeError('The owned mail controller survived cleanup.')


def run(f, original, smtp, previous_values):
    if os.name != 'nt':raise RuntimeError('The native Windows voicemail deletion case is required.')
    f.active_case=CASE
    fields={'name':'Fictional Peer 8103','email':'sink@example.invalid','enabled':'1',
            'voicemail_enabled':'1','voicemail_email':'AttachmentAndDelete','profile':'Available',
            'timeout':'3','auto_status':'','hold_music':'openweb-music',
            'no_answer':'VoiceMail:8103','busy':'VoiceMail:8103','not_registered':'VoiceMail:8103'}
    address='/app/pbx_setup/?view=users&edit=8103'
    runner=original.load_module('windows_owned_delete_mail',f.source/'tests/windows_meeting_owned_process.py').run
    proof=None;primary=None;changed_mode=changed_smtp=False
    try:
        baseline=f.cli('voicemail-delete-status','baseline')
        assert baseline=={'schema':1,'settings_snapshot_owned':True}
        changed_mode=True;f.web.submit(address,'save',fields)
        with socketserver.ThreadingTCPServer(('127.0.0.1',0),handler(smtp.SMTPFixture)) as sink:
            sink.deliveries=[];sink.connections=[];sink.envelopes=[];sink.record_lock=threading.Lock();sink.daemon_threads=True
            sink.awaiting250=threading.Event();sink.release250=threading.Event();sink.acceptance_sent=threading.Event()
            listener=threading.Thread(target=sink.serve_forever,daemon=True);listener.start()
            producer_attempted=False
            try:
                values=dict(previous_values,smtp_port=str(sink.server_address[1]));changed_smtp=True
                f.web.submit('/app/smtp_settings/','save',values)
                producer_attempted=True;prepared=f.cli('voicemail-delete-prepare')
                assert prepared['schema']==1 and prepared['actual_admin_delete_option'] is True and prepared['actual_native_atomic_producer'] is True
                assert prepared['message_exists'] and prepared['file_exists'] and prepared['file_exact'] and prepared['snapshot_exact'] and not prepared['snapshot_cleared'] and prepared['original_recording_preserved']
                proof=delivery(f,original,sink,runner,prepared['expected_sha256'])
            finally:
                sink.release250.set()
                try:
                    if producer_attempted:
                        settles_by=time.monotonic()+15
                        while True:
                            settled=f.cli('voicemail-delete-status','drain')
                            if settled['consumer_released'] and (not sink.awaiting250.is_set() or sink.connections):break
                            if time.monotonic()>=settles_by:raise RuntimeError('The ordinary consumer did not release its owned queue before restoration.')
                            time.sleep(.1)
                finally:
                    sink.shutdown();listener.join(3)
                    if listener.is_alive():raise RuntimeError('The owned SMTP listener survived cleanup.')
    except BaseException as error:primary=error
    finally:
        # Both are real authenticated admin saves. The unchanged parent still
        # requires full canonical factory cleanup after success or failure.
        try:
            if changed_mode:f.web.submit(address,'save',dict(fields,voicemail_email='Attachment'))
        finally:
            if changed_smtp:f.web.submit('/app/smtp_settings/','save',previous_values)
        if changed_mode or changed_smtp:
            restored=f.cli('voicemail-delete-status','restored')
            assert restored=={'schema':1,'mode_and_smtp_restored':True}
    if primary is not None:raise primary
    assert proof is not None
    return proof
