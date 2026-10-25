"""Run the actual meeting UI/media gate inside the existing owned Windows fixture."""
import http.cookiejar
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import urllib.request



def session_user_agent(opener):
    values = [value for name, value in opener.addheaders if name.casefold() == 'user-agent']
    if len(values) != 1 or not isinstance(values[0], str) or not 1 <= len(values[0]) <= 512 or any(ord(char) < 32 or ord(char) == 127 for char in values[0]):
        raise RuntimeError('The actual authenticated fixture user agent is unavailable')
    return values[0]


def browser_result_fields(record):
    keys = {'exit_code', 'report_state', 'cleanup_error_type', 'cleanup_source_basename', 'cleanup_source_line'}
    if type(record) is not dict or set(record) != keys or type(record['exit_code']) is not int or not -2147483648 <= record['exit_code'] <= 4294967295 or record['exit_code'] == 0 or type(record['report_state']) is not str or record['report_state'] not in {'missing', 'invalid', 'passed', 'failed'}:
        return {}
    kind, source, line = (record[name] for name in ('cleanup_error_type', 'cleanup_source_basename', 'cleanup_source_line'))
    if kind is None:
        if source is not None or line is not None: return {}
    elif type(kind) is not str or kind not in {'Error', 'TypeError', 'RangeError', 'ReferenceError', 'SyntaxError', 'TimeoutError', 'other'} or record['report_state'] != 'failed' or type(source) is not str or source not in {'windows-meet-browser.cjs', 'unavailable'} or type(line) is not int or not 0 <= line < 1000000 or (line != 0 if source == 'unavailable' else line < 1):
        return {}
    return {'meeting_browser_result': dict(record)}


def browser_failure_fields(record):
    kinds = {'timeout', 'type', 'reference', 'range', 'security', 'invalid_state', 'not_supported', 'target_closed', 'other'}
    operations = {'none', 'peer_lookup', 'stats', 'analyser_create', 'analyser_source', 'analyser_connect', 'analyser_output', 'spectrum', 'canvas_create', 'canvas_draw', 'canvas_read', 'complete'}
    if not isinstance(record, dict) or set(record) != {'kind', 'operation'} or not isinstance(record['kind'], str) or record['kind'] not in kinds or not isinstance(record['operation'], str) or record['operation'] not in operations:
        return {}
    return {'meeting_browser_failure': dict(record)}


def owner_page_fields(record):
    if not isinstance(record, dict) or set(record) != {'http_status', 'route', 'login_form', 'heading', 'same_origin', 'user_agent_matches'}:
        return {}
    if type(record['http_status']) is not int or not 0 <= record['http_status'] <= 599 or not isinstance(record['route'], str) or record['route'] not in {'meet', 'login', 'logout', 'desktop', 'other'}:
        return {}
    if any(type(record[name]) is not bool for name in ['login_form', 'heading', 'same_origin', 'user_agent_matches']):
        return {}
    return {'meeting_owner_' + name: value for name, value in record.items()}


def media_fields(record):
    booleans = {'observed', 'connected', 'remote_audio_live', 'remote_video_live', 'local_audio_live', 'local_video_live', 'vp8_decoding', 'probe_error'}
    integers = {'decoded_frames', 'encoded_frames', 'inbound_audio_packets', 'outbound_audio_packets', 'inbound_video_packets', 'outbound_video_packets', 'video_colors'}
    enums = {'connection_state': {'new', 'connecting', 'connected', 'disconnected', 'failed', 'closed', 'unavailable'}, 'ice_state': {'new', 'checking', 'connected', 'completed', 'disconnected', 'failed', 'closed', 'unavailable'}, 'visibility': {'visible', 'hidden', 'prerender', 'unavailable'}, 'audio_context': {'running', 'suspended', 'closed', 'interrupted', 'unavailable'}, 'ui_state': {'connected', 'connecting', 'waiting', 'ended', 'rejected', 'connect_error', 'permission_error', 'device_error', 'unavailable', 'other'}}
    if not isinstance(record, dict) or set(record) != {'host', 'guest'}:
        return {}
    safe = {}
    for side in ('host', 'guest'):
        peer = record[side]
        if not isinstance(peer, dict) or set(peer) != booleans | integers | set(enums) | {'tone_ratio', 'power'}:
            return {}
        if any(type(peer[name]) is not bool for name in booleans):
            return {}
        if any(type(peer[name]) is not int or not 0 <= peer[name] <= (14400 if name == 'video_colors' else 2147483647) for name in integers):
            return {}
        if any(not isinstance(peer[name], str) or peer[name] not in allowed for name, allowed in enums.items()):
            return {}
        if any(type(peer[name]) not in (int, float) or not 0 <= peer[name] <= 1 or not math.isfinite(peer[name]) for name in ('tone_ratio', 'power')):
            return {}
        safe[side] = dict(peer)
    return {'meeting_media': safe}


def signaling_fields(record):
    booleans = {'observed', 'endpoint_match', 'counts_capped', 'local_description', 'remote_description', 'admit_ok', 'offer_observed', 'offer_audio_secure', 'offer_video_secure', 'offer_pcmu', 'offer_pcma', 'offer_opus', 'offer_vp8', 'offer_sha256_fingerprint', 'offer_ice_ufrag', 'offer_ice_pwd', 'offer_rtcp_mux', 'offer_bundle', 'offer_connection'}
    counts = {'ws_observed', 'ws_closed', 'ws_errors', 'sent_register', 'sent_invite', 'admit_requests', 'admit_responses', 'status_requests', 'status_responses', 'http_failures', 'api_json_failures'}
    http = {'admit_http_status', 'status_http_status'}
    enums = {'signaling_state': {'stable', 'have-local-offer', 'have-remote-offer', 'have-local-pranswer', 'have-remote-pranswer', 'closed', 'unavailable'}, 'ice_gathering_state': {'new', 'gathering', 'complete', 'unavailable'}, 'member_state': {'waiting', 'admitted', 'left', 'removed', 'unavailable', 'other'}}
    if not isinstance(record, dict) or set(record) != {'host', 'guest'}:
        return {}
    safe = {}
    for side in ('host', 'guest'):
        peer = record[side]
        if not isinstance(peer, dict) or set(peer) != booleans | counts | http | set(enums) | {'register_codes', 'invite_codes'}:
            return {}
        if any(type(peer[name]) is not bool for name in booleans):
            return {}
        if any(type(peer[name]) is not int or not 0 <= peer[name] <= 512 for name in counts):
            return {}
        if any(type(peer[name]) is not int or not 0 <= peer[name] <= 599 for name in http):
            return {}
        if any(not isinstance(peer[name], str) or peer[name] not in allowed for name, allowed in enums.items()):
            return {}
        if any(not isinstance(peer[name], list) or len(peer[name]) > 16 or any(type(code) is not int or not 100 <= code <= 699 for code in peer[name]) for name in ('register_codes', 'invite_codes')):
            return {}
        safe[side] = dict(peer)
    return {'meeting_signaling': safe}


def path_fields(record):
    ws = dict(booleans={'observed','connected','sent','response_received','closed_exact','large_sent','large_response_received'}, integers={'status_code':699,'large_status_code':699,'elapsed_ms':6000}, enums={'phase':{'connect','send','receive','complete','unavailable'},'error_kind':{'none','timeout','tls','websocket','other','unavailable'}})
    pg = dict(booleans={'observed','read_only','query_visible','counts_capped'}, integers={name:512 for name in ('total','active','idle','idle_in_transaction','wait_lock','meeting_select','meeting_update','meeting_insert','meeting_other','meeting_wait_lock')}, enums={'error_kind':{'none','timeout','database','unavailable'}})
    http = dict(booleans={'observed','completed','ok'}, integers={'http_status':599,'elapsed_ms':5000}, enums={'member_state':{'waiting','admitted','left','removed','unavailable','other'},'error_kind':{'none','timeout','tls','http','invalid_json','other','unavailable'}})
    specs={'backend':ws,'frontend':ws,'fragmented_backend':ws,'fragmented_frontend':ws,'database':pg,'host_http':http,'guest_http':http}
    if not isinstance(record,dict) or set(record)!={'before','after'}:
        return {}
    safe={}
    for stage in ('before','after'):
        row=record[stage]
        if not isinstance(row,dict) or set(row)!=set(specs):
            return {}
        safe[stage]={}
        for name,spec in specs.items():
            value=row[name]
            if not isinstance(value,dict) or set(value)!=spec['booleans']|set(spec['integers'])|set(spec['enums']):
                return {}
            if any(type(value[key]) is not bool for key in spec['booleans']) or any(type(value[key]) is not int or not 0<=value[key]<=maximum for key,maximum in spec['integers'].items()) or any(not isinstance(value[key],str) or value[key] not in allowed for key,allowed in spec['enums'].items()):
                return {}
            safe[stage][name]=dict(value)
    return {'meeting_path':safe}


def wss_child_fields(record):
    if type(record) is not list or not 1 <= len(record) <= 2:
        return {}
    safe = []; labels = set()
    ps_types = {'RuntimeException','PSInvalidOperationException','InvalidOperationException','CmdletInvocationException','CommandNotFoundException','FileNotFoundException','IOException','UnauthorizedAccessException','TypeLoadException','CryptographicException','WebSocketException','AuthenticationException','TimeoutException','ManagementException','Exception','external_error'}
    def integer(value, low, high): return type(value) is int and low <= value <= high
    for value in record:
        if type(value) is not dict or set(value) != {'schema','label','reason','outcome'} or type(value['schema']) is not int or value['schema'] != 1 or type(value['label']) is not str or value['label'] not in {'before','after'} or value['label'] in labels or type(value['reason']) is not str or value['reason'] not in {'report_missing','report_invalid'}:
            return {}
        child = value['outcome']
        if type(child) is not dict or set(child) != {'exit_code','error_type','code_kind','errno','killed','signal','elapsed_ms','powershell_state','powershell'}:
            return {}
        if child['exit_code'] is not None and not integer(child['exit_code'], -2147483648, 4294967295) or child['errno'] is not None and not integer(child['errno'], -2147483648, 2147483647) or child['killed'] is not None and type(child['killed']) is not bool or not integer(child['elapsed_ms'], 0, 32000):
            return {}
        if type(child['error_type']) is not str or child['error_type'] not in {'none','Error','TypeError','RangeError','TimeoutError','AbortError','other'} or type(child['code_kind']) is not str or child['code_kind'] not in {'none','exit','ENOENT','EACCES','EPERM','ETIMEDOUT','ABORT_ERR','ERR_CHILD_PROCESS_STDIO_MAXBUFFER','other'} or type(child['signal']) is not str or child['signal'] not in {'none','SIGTERM','SIGKILL','other'} or type(child['powershell_state']) is not str or child['powershell_state'] not in {'absent','invalid','closed'}:
            return {}
        ps = child['powershell']
        if child['powershell_state'] == 'closed':
            if type(ps) is not dict or set(ps) != {'schema','state','producer','error_type','source_basename','source_line','hresult'} or type(ps['schema']) is not int or ps['schema'] != 1 or type(ps['state']) is not str or ps['state'] != 'failed' or type(ps['producer']) is not str or ps['producer'] != 'windows-meet-wss-path.ps1' or type(ps['error_type']) is not str or ps['error_type'] not in ps_types or type(ps['source_basename']) is not str or ps['source_basename'] not in {'windows-meet-wss-path.ps1','unavailable'} or not integer(ps['source_line'], 0, 999999) or not integer(ps['hresult'], -2147483648, 2147483647) or (ps['source_line'] != 0 if ps['source_basename'] == 'unavailable' else ps['source_line'] < 1):
                return {}
        elif ps is not None:
            return {}
        labels.add(value['label'])
        safe.append(dict(value, outcome=dict(child, powershell=dict(ps) if ps is not None else None)))
    return {'meeting_wss_child_failure': safe}


def completed_paths(record):
    paths = path_fields(record)
    if not paths:
        return False
    for stage in paths['meeting_path'].values():
        for name in ['backend', 'frontend', 'fragmented_backend', 'fragmented_frontend']:
            peer = stage[name]
            if not all(peer[field] for field in ['observed', 'connected', 'sent', 'response_received', 'large_sent', 'large_response_received', 'closed_exact']) or peer['status_code'] != 200 or peer['large_status_code'] != 200 or peer['phase'] != 'complete' or peer['error_kind'] != 'none':
                return False
    return True


def run(fixture):
    if os.name != 'nt' or os.environ.get('OPENWEB_WINDOWS_NATIVE_TEST') != '1' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('GITHUB_REPOSITORY') != 'embire2/openwebpbx':
        raise RuntimeError('An explicitly disposable Windows native fixture is required')
    fixture.active_case = 'native_windows_meeting_browser_media'
    dependencies = fixture.evidence / 'meeting-browser-dependencies'
    dependencies.mkdir(exist_ok=True)
    source = fixture.source / 'tests/windows-meet-browser'
    for name in ['package.json', 'package-lock.json']:
        shutil.copyfile(source / name, dependencies / name)
    node = shutil.which('node.exe')
    npm = shutil.which('npm.cmd')
    if not node or not npm:
        raise RuntimeError('The hosted runner must provide Node and npm for its browser qualification')
    npm_cli = Path(npm).parent / 'node_modules/npm/bin/npm-cli.js'
    if not npm_cli.is_file():
        raise RuntimeError('The owned npm CLI is unavailable')
    commands = [('dependencies', [node, str(npm_cli), 'ci', '--prefix', str(dependencies), '--ignore-scripts', '--no-audit', '--fund=false', '--fetch-timeout=30000', '--fetch-retries=2'])]
    cookies = []
    for handler in fixture.web.open.handlers:
        if isinstance(handler, urllib.request.HTTPCookieProcessor):
            for cookie in handler.cookiejar:
                cookies.append(dict(name=cookie.name, value=cookie.value, domain=cookie.domain, path=cookie.path, secure=bool(cookie.secure), httpOnly=bool(cookie.has_nonstandard_attr('HttpOnly')), sameSite='Lax'))
    if not cookies:
        raise RuntimeError('The normal authenticated fixture session is unavailable')
    report = fixture.evidence / 'meeting-browser.safe.json'
    settings = fixture.evidence / 'meeting-browser.private.json'
    path_probe=dict(powershell=str(Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe'),wssScript=str(fixture.source/'tests/windows-meet-wss-path.ps1'),php=str(fixture.php),fixtureScript=str(fixture.script),fixtureInput=str(fixture.path),caFile=str(fixture.evidence/'fixture-root.pem'))
    settings.write_text(json.dumps(dict(origin=fixture.s['public_url'].rstrip('/'), cookies=cookies, userAgent=session_user_agent(fixture.web.open), subject='Owned Windows video '+fixture.s['scope'], dependencies=str(dependencies), report=str(report),pathProbe=path_probe)), encoding='utf-8')
    commands.append(('browser', [node, str(fixture.source / 'tests/windows-meet-browser.cjs'), str(settings)]))
    try:
        for phase, command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=240)
            (fixture.evidence / ('meeting-'+phase+'.private.log')).write_text(result.stdout+result.stderr, encoding='utf-8')
            if result.returncode:
                stage='dependencies' if phase=='dependencies' else 'unknown'
                owner_fields={}
                observed_media={}
                observed_signaling={}
                observed_path={}; observed_wss_child={}
                browser_result=dict(exit_code=result.returncode, report_state='missing', cleanup_error_type=None, cleanup_source_basename=None, cleanup_source_line=None)
                if phase=='browser' and report.is_file():
                    try:
                        browser_result['report_state']='invalid'
                        with report.open('rb') as stream: raw=stream.read(65537)
                        if len(raw) > 65536: raise ValueError()
                        failed=json.loads(raw.decode('utf-8'))
                        if type(failed) is dict and type(failed.get('schema')) is int and failed['schema']==1 and type(failed.get('state')) is str and failed['state'] in {'passed','failed'}:
                            browser_result['report_state']=failed['state']
                        if type(failed) is dict and type(failed.get('schema')) is int and failed['schema']==1 and failed.get('state')=='failed' and type(failed.get('phase')) is str and failed['phase'] in {'browser_start','owner_page','create','host_join','guest_join','admission','decoded_media','mute','unmute','end','cleanup'}:
                            stage=failed['phase']
                            if stage=='cleanup':
                                closed=failed.get('cleanup_failure')
                                if type(closed) is dict and set(closed)=={'error_type','source_basename','source_line'}:
                                    candidate=dict(browser_result, cleanup_error_type=closed['error_type'], cleanup_source_basename=closed['source_basename'], cleanup_source_line=closed['source_line'])
                                    if browser_result_fields(candidate): browser_result=candidate
                            if stage=='owner_page':owner_fields=owner_page_fields(failed.get('owner_page'))
                            if stage in {'decoded_media','mute','unmute','end'}:
                                observed_media=media_fields(failed.get('meeting_media'))
                                observed_media.update(browser_failure_fields(failed.get('browser_failure')))
                            if stage in {'host_join','guest_join','admission','decoded_media','mute','unmute','end'}:observed_signaling=signaling_fields(failed.get('meeting_signaling'))
                            observed_path=path_fields(failed.get('meeting_path'))
                            if stage == 'browser_start': observed_wss_child=wss_child_fields(failed.get('meeting_wss_child_failure'))
                    except (ValueError,OSError):pass
                fixture.active_case='native_windows_meeting_'+stage
                error=RuntimeError('The actual Windows meeting '+phase+' qualification did not pass')
                error.meeting_owner_failure=owner_fields
                error.meeting_media_failure=observed_media
                error.meeting_signaling_failure=observed_signaling
                error.meeting_path_failure=observed_path
                error.meeting_wss_child_failure=observed_wss_child
                if phase=='browser':
                    try: error.meeting_browser_result=browser_result_fields(browser_result)
                    except BaseException: pass
                raise error
        facts = json.loads(report.read_text())
        if facts.get('schema') != 1 or facts.get('state') != 'passed' or len(facts.get('checks', [])) != 9:
            raise RuntimeError('The Windows browser meeting media evidence is incomplete')
        if not completed_paths(facts.get('meeting_path')):
            raise RuntimeError('Both native Windows SIP paths must preserve complete fragmented messages')
        for side in ['host', 'guest']:
            proof = facts[side]
            if proof['decoded_frames'] < 10 or proof['video_colors'] <= 8 or proof['tone_ratio'] <= .65 or proof['power'] <= .00001 or set(proof['codecs']) != {'video/VP8'}:
                raise RuntimeError('The actual Windows browser did not decode the independent meeting media')
        fixture.record('native_windows_meeting_browser_video_audio', checks=len(facts['checks']), wss_roundtrips=16, host_frames=facts['host']['decoded_frames'], guest_frames=facts['guest']['decoded_frames'], host_tone_ratio=facts['host']['tone_ratio'], guest_tone_ratio=facts['guest']['tone_ratio'], physical_camera='unqualified')
    finally:
        settings.unlink(missing_ok=True)
