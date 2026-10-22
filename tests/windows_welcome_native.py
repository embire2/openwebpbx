"""Actual PHP/PostgreSQL welcome MIME capture; no external recipient or relay.

The independently pinned QR decoder is a private test dependency. Nothing is
installed into the server runtime. Tenant custody/TLS readiness are modelled in
this one fixture; separate alias/IIS and external-client gates remain required.
"""
from contextlib import contextmanager, nullcontext
from email.parser import BytesParser
from email.policy import default
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import socketserver
import stat
import subprocess
import sys
import threading
import time
import urllib.request
import zipfile

DECODERS = {
    'nt': ('zxing_cpp-3.1.1-cp312-abi3-win_amd64.whl',
           'https://files.pythonhosted.org/packages/7d/14/055c5a68a50bdde8378ced94e63f9ce340311e51c87b947f9b95fe69f51a/zxing_cpp-3.1.1-cp312-abi3-win_amd64.whl',
           1003677, '29f98a91148171460b47a942d137ecc90c4b8097636f23cca65263a56bb025d3'),
    'posix': ('zxing_cpp-3.1.1-cp312-abi3-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl',
              'https://files.pythonhosted.org/packages/0c/30/79683cf7139ee5325fbc68169eb8dc1cb2033ec43339b5f39de990f909a7/zxing_cpp-3.1.1-cp312-abi3-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl',
              1096795, '9cf67341949946307d086b302cefd453fb47bc6d6ddc7d088839e9481982757b'),
}


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


def private_directory(path):
    path.mkdir(mode=0o700)
    if os.name != 'nt':
        return
    encoded = base64.b64encode(str(path).encode()).decode()
    script = ("$ErrorActionPreference='Stop';$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + encoded + "'));"
              "$a=[Security.AccessControl.DirectorySecurity]::new();$a.SetAccessRuleProtection($true,$false);"
              "$a.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544');"
              "foreach($s in 'S-1-5-18','S-1-5-32-544'){$a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$s,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))};Set-Acl -LiteralPath $p -AclObject $a")
    command = base64.b64encode(script.encode('utf-16le')).decode()
    ps = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    subprocess.run([str(ps), '-NoProfile', '-NonInteractive', '-EncodedCommand', command],
                   capture_output=True, check=True, timeout=20)


def remove_private_config(work):
    """Remove only this fixture's ordinary credential copy, on every outcome."""
    path = work / 'config.conf'
    try:
        item = path.lstat()
    except FileNotFoundError:
        return
    if (work.is_symlink() or not work.is_dir() or not stat.S_ISREG(item.st_mode)
            or item.st_nlink != 1 or getattr(item, 'st_file_attributes', 0) & 0x400
            or path.resolve().parent != work.resolve()):
        raise RuntimeError('The exact private credential copy changed; cleanup refused.')
    path.unlink()


def decoder(work, wheel_input=None):
    name, url, size, digest = DECODERS[os.name]
    wheel = work / name
    if wheel_input:
        raw = Path(wheel_input).read_bytes()
    else:
        with urllib.request.urlopen(url, timeout=45) as response:
            raw = response.read(size + 1)
    if len(raw) != size or hashlib.sha256(raw).hexdigest() != digest:
        raise RuntimeError('The pinned private QR decoder differs.')
    wheel.write_bytes(raw)
    directory = work / 'decoder'
    private_directory(directory)
    with zipfile.ZipFile(wheel) as archive:
        members = archive.infolist()
        if len(members) > 100 or sum(entry.file_size for entry in members) > 10_000_000:
            raise RuntimeError('The private QR decoder inventory is too large.')
        seen = set()
        for entry in members:
            path = Path(entry.filename)
            if (path.is_absolute() or '..' in path.parts or '\\' in entry.filename
                    or ':' in entry.filename or entry.filename in seen
                    or (entry.external_attr >> 16) & 0o170000 == 0o120000):
                raise RuntimeError('The private QR decoder archive path is unsafe.')
            seen.add(entry.filename)
            target = directory / path
            if entry.is_dir():
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
            else:
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))
    if 'zxingcpp' in sys.modules:
        raise RuntimeError('A different QR decoder is already imported.')
    sys.path.insert(0, str(directory))
    try:
        import zxingcpp
    finally:
        sys.path.pop(0)
    imported = Path(zxingcpp.__file__).resolve()
    if not imported.is_relative_to(directory.resolve()) or imported.relative_to(directory.resolve()).as_posix() not in seen:
        raise RuntimeError('The private QR decoder import escaped its inventory.')
    return zxingcpp, digest


@contextmanager
def native_maintenance(source):
    backups = module('welcome_owned_windows_backups', Path('C:/OpenWebPBX/tools/backups.py'))
    deadline = time.monotonic() + 30
    while True:
        guard = backups.exclusive_guard(Path(os.environ['ProgramData']) / 'OpenWebPBX/upgrade.lock')
        try:
            guard.__enter__()
            break
        except backups.BackupBusy:
            if time.monotonic() >= deadline:
                raise RuntimeError('The welcome fixture could not acquire its maintenance lock.') from None
            time.sleep(.25)
    try:
        yield
    finally:
        guard.__exit__(None, None, None)


def run_fixture(input_path, source, php, evidence, *, portable=False, wheel_input=None):
    os.umask(0o077)
    source, php, evidence = Path(source), Path(php), Path(evidence)
    decode_png = module('welcome_owned_png_decoder', Path(__file__).with_name('windows_welcome_qr.py')).decode_png
    work = evidence / ('welcome-' + secrets.token_hex(12))
    private_directory(work)
    helper = source / 'tests/windows_welcome_native.php'
    base = [str(php), str(helper)]
    tail = ['--portable-socket-factory'] if portable else []
    serial = 0
    checks = 0

    def check(condition, message):
        nonlocal checks
        if not condition:
            raise RuntimeError(message)
        checks += 1

    def operation(action, *args, json_result=True):
        nonlocal serial
        serial += 1
        result = subprocess.run([*base, action, str(input_path), str(work), *map(str, args), *tail],
                                cwd=source, capture_output=True, timeout=45)
        (work / f'{serial}-{action}.private.out').write_bytes(result.stdout)
        (work / f'{serial}-{action}.private.err').write_bytes(result.stderr)
        if result.returncode or result.stderr:
            error = RuntimeError('The private PHP welcome operation failed: ' + action)
            for line in reversed(result.stdout.splitlines()):
                if len(line) > 2048:
                    continue
                try:
                    failure = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if (isinstance(failure, dict) and failure.get('state') == 'failed'
                        and failure.get('phase') in {'input', 'database', 'bootstrap', 'queue', 'dispatch', 'inspect', 'suppress', 'cleanup'}
                        and failure.get('error_type') in {'RuntimeException', 'PDOException', 'Error', 'TypeError', 'ValueError', 'JsonException', 'Exception'}
                        and failure.get('source_basename') in {'windows_welcome_native.php', 'pbx_mobile.php', 'pbx_mobile_welcome.php', 'email.php', 'outgoing_mail.php', 'email_send.php', 'database.php', 'config.php', 'settings.php', 'external_component'}
                        and type(failure.get('source_line')) is int and 1 <= failure['source_line'] <= 100000
                        and isinstance(failure.get('sqlstate'), str)
                        and (failure['sqlstate'] == 'none' or len(failure['sqlstate']) == 5 and failure['sqlstate'].isascii() and failure['sqlstate'].isalnum() and failure['sqlstate'].upper() == failure['sqlstate'])):
                    error.welcome_failure = {'welcome_' + key: failure[key] for key in ('phase', 'error_type', 'source_basename', 'source_line', 'sqlstate')}
                    break
            raise error
        return json.loads(result.stdout) if json_result else result.stdout

    smtp = module('welcome_owned_loopback_smtp', source / 'tests/smtp_transport_integration.py')
    primary = cleanup_error = None
    prepared = False
    result = None
    with (nullcontext() if portable else native_maintenance(source)):
        with socketserver.ThreadingTCPServer(('127.0.0.1', 0), smtp.SMTPFixture) as sink:
            sink.deliveries, sink.connections, sink.envelopes = [], [], []
            sink.record_lock = threading.Lock()
            sink.daemon_threads = True
            thread = threading.Thread(target=sink.serve_forever, daemon=True)
            thread.start()
            children = []
            try:
                decoded, decoder_sha = decoder(work, wheel_input)
                prepared_result = operation('prepare', sink.server_address[1])
                prepared = True
                check(prepared_result['state'] == 'prepared', 'The actual welcome queue was not prepared.')
                check(prepared_result['schema_isolated'] is True and prepared_result['same_framework_backend'] is True,
                      'The real framework connection was not isolated.')
                check(prepared_result['actual_windows_native'] is (os.name == 'nt'), 'The PHP platform does not match the fixture runtime.')
                queue = prepared_result['queue_uuid']
                for _ in range(2):
                    children.append(subprocess.Popen([*base, 'dispatch', str(input_path), str(work), queue, *tail],
                                                      cwd=source, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
                    time.sleep(.1)
                for index, child in enumerate(children):
                    out, error = child.communicate(timeout=45)
                    (work / f'dispatch-{index}.private.out').write_bytes(out)
                    (work / f'dispatch-{index}.private.err').write_bytes(error)
                    check(child.returncode == 0 and not error, 'The actual concurrent dispatcher failed.')
                check(len(sink.deliveries) == 1, 'The concurrent welcome dispatch was not singular.')
                expected = json.loads((work / 'expected.private.json').read_text())
                message_bytes = sink.deliveries[0][1]
                (work / 'captured.private.eml').write_bytes(message_bytes)
                message = BytesParser(policy=default).parsebytes(message_bytes)
                parts = list(message.walk())
                png = [part for part in parts if part.get_content_type() == 'image/png']
                config = [part for part in parts if part.get_content_type() == 'application/vnd.openwebpbx.config+json']
                html = [part for part in parts if part.get_content_type() == 'text/html']
                check(len(png) == len(config) == len(html) == 1, 'The actual welcome MIME parts differ.')
                check(png[0].get_content_disposition() == 'inline', 'The QR was not inline.')
                check(str(png[0]['Content-ID']).strip('<>') in html[0].get_content(), 'The HTML and QR content IDs differ.')
                image = png[0].get_payload(decode=True)
                check(hashlib.sha256(image).hexdigest() == expected['png_sha256'], 'The transported QR bytes differ.')
                payload = json.loads(config[0].get_payload(decode=True))
                check(payload == expected['payload'] == decode_png(image, decoded), 'The independently decoded QR and setup file differ.')
                renderer_root = Path('C:/OpenWebPBX/web') if os.name == 'nt' else source
                rendered = subprocess.run([str(php), '-n', '-r',
                                           'define("PROJECT_ROOT",$argv[1]);require PROJECT_ROOT."/resources/classes/pbx_mobile.php";echo pbx_mobile::qrPng(stream_get_contents(STDIN));',
                                           str(renderer_root)], input=config[0].get_payload(decode=True), capture_output=True, timeout=20)
                check(rendered.returncode == 0 and not rendered.stderr and rendered.stdout == image,
                      'The exact installed QR renderer did not run without php.ini or GD.')
                for damaged in (b'', image[:-1], image[:40] + bytes([image[40] ^ 1]) + image[41:], image + b'x'):
                    refused = False
                    try:
                        decode_png(damaged, decoded)
                    except ValueError:
                        refused = True
                    check(refused, 'The independent decoder accepted a damaged setup PNG.')
                check(config[0].get_content_disposition() == 'attachment', 'The setup config is not an attachment.')
                check(config[0].get_filename() == 'OpenWebPBX-8100.openwebpbx', 'The setup filename differs.')
                check(set(payload) == {'type', 'version', 'server', 'code', 'extension'}, 'A password or unexpected setup field was included.')
                check(payload['server'].startswith('https://qa-welcome-') and payload['server'].endswith('.openwebpbx.com'), 'The modelled tenant alias differs.')
                check(len(payload['code']) == 64 and payload['extension'] == '8100', 'The extension/setup code differs.')
                check(sink.envelopes == ['MAIL FROM:<welcome@example.invalid>'] and sink.connections == [(False, 0)], 'The loopback sender/no-AUTH transport differs.')
                check(str(message['To']) == 'welcome@example.invalid', 'The private recipient differs.')
                check(str(message['From']) == 'Native Welcome Fixture <welcome@example.invalid>', 'The global sender identity differs.')
                inspected = operation('inspect')
                check(inspected['delivery_state'] == 'sent' and inspected['inbox_claim_refused'] is True, 'SMTP acceptance was not honestly reported.')
                check(inspected['public_exact'] is True and inspected['config_exact'] is True, 'Original public rows/configuration changed.')
                used = operation('suppress')
                operation('dispatch', used['queue_uuid'], json_result=False)
                inspected = operation('inspect')
                check(inspected['delivery_state'] == 'used' and inspected['queue_states'].count('cancelled') == 1, 'The used setup invitation was not cancelled.')
                check(len(sink.deliveries) == 1, 'A used invitation was delivered.')
                result = {'state': 'passed', 'actual_php_postgresql_dispatcher': True,
                          'two_concurrent_dispatchers': True, 'one_actual_loopback_delivery': True,
                          'inline_qr_cid_exact': True, 'independent_qr_decoded': True,
                          'qr_and_attached_config_exact': True, 'password_free_one_use_setup': True,
                          'used_invitation_suppressed': True, 'same_framework_backend': True,
                          'no_php_ini_or_gd_renderer': True,
                          'alias_custody_modelled': True, 'tls_readiness_modelled': True,
                          'gd_required': False, 'no_external_mail': True,
                          'actual_windows_native': os.name == 'nt', 'decoder_sha256': decoder_sha}
            except BaseException as error:
                primary = error
            finally:
                for child in children:
                    if child.poll() is None:
                        try:
                            child.kill()
                            child.communicate(timeout=5)
                        except BaseException as error:
                            if cleanup_error is None:
                                cleanup_error = error
                try:
                    if prepared or (work / 'state.private.json').exists():
                        cleanup = operation('cleanup')
                        check(cleanup == {'state': 'cleaned', 'public_exact': True, 'config_exact': True,
                                          'owned_schema_removed': True, 'only_owned_locks_removed': True},
                              'The actual welcome fixture cleanup is incomplete.')
                        if result is not None:
                            result.update(checks=checks, public_rows_exact=True, global_mail_config_exact=True,
                                          owned_schema_and_locks_removed=True)
                except BaseException as error:
                    if cleanup_error is None:
                        cleanup_error = error
                finally:
                    try:
                        remove_private_config(work)
                        if result is not None:
                            result['private_credentials_removed'] = True
                    except BaseException as error:
                        if cleanup_error is None:
                            cleanup_error = error
                sink.shutdown()
                thread.join(3)
    if cleanup_error:
        error = RuntimeError('The welcome fixture cleanup requires review.')
        error.welcome_failure = dict(getattr(primary, 'welcome_failure', None) or getattr(cleanup_error, 'welcome_failure', {}))
        error.welcome_failure['welcome_cleanup_failed'] = True
        raise error from cleanup_error
    if primary:
        raise primary
    (work / 'mime.safe.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('input')
    parser.add_argument('--source', required=True)
    parser.add_argument('--php', required=True)
    parser.add_argument('--evidence', required=True)
    parser.add_argument('--portable-socket-factory', action='store_true')
    parser.add_argument('--decoder-wheel')
    args = parser.parse_args()
    print(json.dumps(run_fixture(args.input, args.source, args.php, args.evidence,
                                 portable=args.portable_socket_factory, wheel_input=args.decoder_wheel)))
