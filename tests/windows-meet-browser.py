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
    settings.write_text(json.dumps(dict(origin=fixture.s['public_url'].rstrip('/'), cookies=cookies, userAgent=session_user_agent(fixture.web.open), subject='Owned Windows video '+fixture.s['scope'], dependencies=str(dependencies), report=str(report))), encoding='utf-8')
    commands.append(('browser', [node, str(fixture.source / 'tests/windows-meet-browser.cjs'), str(settings)]))
    try:
        for phase, command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=240)
            (fixture.evidence / ('meeting-'+phase+'.private.log')).write_text(result.stdout+result.stderr, encoding='utf-8')
            if result.returncode:
                stage='dependencies' if phase=='dependencies' else 'unknown'
                owner_fields={}
                observed_media={}
                if phase=='browser' and report.is_file():
                    try:
                        failed=json.loads(report.read_text(encoding='utf-8'))
                        if failed.get('schema')==1 and failed.get('state')=='failed' and failed.get('phase') in {'browser_start','owner_page','create','host_join','guest_join','admission','decoded_media','mute','unmute','end'}:
                            stage=failed['phase']
                            if stage=='owner_page':owner_fields=owner_page_fields(failed.get('owner_page'))
                            if stage in {'decoded_media','mute','unmute','end'}:observed_media=media_fields(failed.get('meeting_media'))
                    except (ValueError,OSError):pass
                fixture.active_case='native_windows_meeting_'+stage
                error=RuntimeError('The actual Windows meeting '+phase+' qualification did not pass')
                error.meeting_owner_failure=owner_fields
                error.meeting_media_failure=observed_media
                raise error
        facts = json.loads(report.read_text())
        if facts.get('schema') != 1 or facts.get('state') != 'passed' or len(facts.get('checks', [])) != 7:
            raise RuntimeError('The Windows browser meeting media evidence is incomplete')
        for side in ['host', 'guest']:
            proof = facts[side]
            if proof['decoded_frames'] < 10 or proof['video_colors'] <= 8 or proof['tone_ratio'] <= .65 or proof['power'] <= .00001 or set(proof['codecs']) != {'video/VP8'}:
                raise RuntimeError('The actual Windows browser did not decode the independent meeting media')
        fixture.record('native_windows_meeting_browser_video_audio', checks=len(facts['checks']), host_frames=facts['host']['decoded_frames'], guest_frames=facts['guest']['decoded_frames'], host_tone_ratio=facts['host']['tone_ratio'], guest_tone_ratio=facts['guest']['tone_ratio'], physical_camera='unqualified')
    finally:
        settings.unlink(missing_ok=True)
