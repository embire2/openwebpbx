"""Run the actual meeting UI/media gate inside the existing owned Windows fixture."""
import http.cookiejar
import json
import os
from pathlib import Path
import shutil
import subprocess
import urllib.request


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
    settings.write_text(json.dumps(dict(origin=fixture.s['public_url'].rstrip('/'), cookies=cookies, subject='Owned Windows video '+fixture.s['scope'], dependencies=str(dependencies), report=str(report))), encoding='utf-8')
    commands.append(('browser', [node, str(fixture.source / 'tests/windows-meet-browser.cjs'), str(settings)]))
    try:
        for phase, command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=240)
            (fixture.evidence / ('meeting-'+phase+'.private.log')).write_text(result.stdout+result.stderr, encoding='utf-8')
            if result.returncode:
                stage='dependencies' if phase=='dependencies' else 'unknown'
                if phase=='browser' and report.is_file():
                    try:
                        failed=json.loads(report.read_text(encoding='utf-8'))
                        if failed.get('schema')==1 and failed.get('state')=='failed' and failed.get('phase') in {'browser_start','owner_page','create','host_join','guest_join','admission','decoded_media','mute','unmute','end'}:
                            stage=failed['phase']
                    except (ValueError,OSError):pass
                fixture.active_case='native_windows_meeting_'+stage
                raise RuntimeError('The actual Windows meeting '+phase+' qualification did not pass')
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
