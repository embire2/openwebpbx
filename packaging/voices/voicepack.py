#!/usr/bin/env python3
"""Create, verify and package a versioned offline PBX voice pack.

Generation sends catalogue text only to ElevenLabs. It never reads caller audio,
PBX credentials, phone numbers, identity numbers or a customer backup.
"""
from __future__ import annotations

import argparse
import array
import concurrent.futures
import datetime
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request
import wave

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOG = ROOT / 'app/pbx_setup/resources/voicepacks/1.0.2/catalog.json'
API = 'https://api.elevenlabs.io/v1'
RATES = {8000, 16000, 32000, 48000}
HASH = re.compile(r'^[a-f0-9]{64}$')


class PackError(RuntimeError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def relative(name):
    if not isinstance(name, str) or not name or '\\' in name:
        raise PackError('Invalid voice path.')
    p = PurePosixPath(name)
    if p.is_absolute() or any(x in {'', '.', '..'} or x.startswith('.') for x in name.split('/')):
        raise PackError('Unsafe voice path.')
    if p.suffix != '.wav' or not (name.startswith('en/us/callie/') or name.startswith('openwebpbx/')):
        raise PackError('Only catalogue-owned spoken WAV paths are allowed.')
    if any(x in name for x in ['music/', 'recordings/', 'voicemail/recordings/']):
        raise PackError('Customer media and music cannot enter a voice pack.')
    return p


def load_catalog(path):
    c = json.loads(Path(path).read_text(encoding='utf-8'))
    if c.get('schema') != 1 or not re.fullmatch(r'\d+\.\d+\.\d+', c.get('version', '')):
        raise PackError('Invalid catalogue version.')
    if c.get('provider') != 'ElevenLabs' or c.get('locale') not in {'en-GB', 'en-ZA'}:
        raise PackError('The catalogue must identify its provider and supported English locale.')
    if not re.fullmatch('[A-Za-z0-9]{20}', c.get('voice_id', '')):
        raise PackError('Invalid voice identity.')
    seen, ids = set(), set()
    for prompt in c['prompts']:
        if prompt['id'] in ids or not prompt.get('text', '').strip():
            raise PackError('Missing or duplicate script.')
        ids.add(prompt['id'])
        text = prompt.get('spoken_text', prompt['text'])
        if not isinstance(text, str) or len(text) > 3000 or any(ord(x) < 32 for x in text):
            raise PackError('Invalid synthesis text.')
        for t in prompt['targets']:
            name = str(relative(t['path']))
            if name in seen or t.get('rate') not in RATES:
                raise PackError('Duplicate voice destination or unsupported rate.')
            seen.add(name)
    originals = c['stock_original_sha256']
    if not isinstance(originals, dict) or not set(originals).issubset(seen):
        raise PackError('Original inventory is inconsistent.')
    for name, sha in originals.items():
        relative(name)
        if not isinstance(sha, str) or not HASH.fullmatch(sha):
            raise PackError('Invalid original voice digest.')
    previous = c.get('previous_system_sha256', {})
    if not isinstance(previous, dict) or not set(previous).issubset(seen):
        raise PackError('Previous system inventory is inconsistent.')
    for name, sha in previous.items():
        relative(name)
        if not isinstance(sha, str) or not HASH.fullmatch(sha):
            raise PackError('Invalid previous system voice digest.')
    if previous and (not isinstance(c.get('previous_pack_sha256'), str) or not HASH.fullmatch(c['previous_pack_sha256'])):
        raise PackError('A previous system inventory requires its authenticated pack identity.')
    return c


def safe_file(root, name):
    p = Path(root) / relative(name)
    for q in [p, *p.parents]:
        if q.is_symlink():
            raise PackError('Symbolic links are not permitted in voice paths.')
        if q == Path(root):
            break
    return p


def audio_info(data, expected_rate=None):
    try:
        with wave.open(io.BytesIO(data), 'rb') as wav:
            if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getcomptype() != 'NONE':
                raise PackError('Prompts must be mono 16-bit PCM WAV.')
            rate, frames = wav.getframerate(), wav.getnframes()
            if expected_rate is not None and rate != expected_rate:
                raise PackError('Prompt rate does not match its destination.')
            pcm = wav.readframes(frames)
            if len(pcm) != frames * 2:
                raise PackError('Truncated prompt audio.')
    except (EOFError, wave.Error) as e:
        raise PackError('Malformed prompt WAV.') from e
    duration = frames / rate
    if not 0.08 <= duration <= 120:
        raise PackError('Prompt length is outside the permitted range.')
    samples = array.array('h', pcm)
    if sys.byteorder != 'little':
        samples.byteswap()
    peak = max(abs(x) for x in samples)
    rms = math.sqrt(sum(x*x for x in samples) / len(samples))
    clipped = sum(abs(x) >= 32760 for x in samples) / len(samples)
    if peak < 100 or rms < 20 or clipped > .005:
        raise PackError('Prompt is silent or materially clipped.')
    return {'rate': rate, 'channels': 1, 'sample_width': 2, 'frames': frames,
            'seconds': round(duration, 6), 'peak': peak, 'rms': round(rms, 3),
            'clipped_fraction': round(clipped, 8), 'sha256': digest(data), 'bytes': len(data)}


def api_key(env_file):
    key = os.environ.get('ELEVENLABS_API_KEY', '')
    if not key and env_file:
        p = Path(env_file)
        if p.is_symlink() or p.stat().st_mode & 0o077:
            raise PackError('The API-key file must be private and must not be a link.')
        for line in p.read_text(encoding='utf-8').splitlines():
            if line.startswith('ELEVENLABS_API_KEY='):
                key = line.split('=', 1)[1].strip().strip('"\'')
    if not key or any(x.isspace() for x in key):
        raise PackError('Configure ELEVENLABS_API_KEY privately before generation.')
    return key


def request_json(path, key):
    request = urllib.request.Request(API + path, headers={'xi-api-key': key})
    try:
        with urllib.request.urlopen(request, timeout=40) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        raise PackError('ElevenLabs metadata request refused (HTTP %s).' % e.code) from None


def synthesis(c, text, key):
    request = urllib.request.Request(API + '/text-to-speech/' + c['voice_id'] + '?output_format=pcm_44100',
        data=canonical({'text': text, 'model_id': c['model_id'], 'voice_settings': c['voice_settings'], 'seed': 101}),
        headers={'xi-api-key': key, 'Content-Type': 'application/json', 'Accept': 'audio/pcm'})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                raw = response.read(44100 * 2 * 120 + 1)
                request_id = response.headers.get('request-id', '')
            break
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 3:
                time.sleep(min(20, 2 ** (attempt+1)))
                continue
            raise PackError('ElevenLabs generation refused (HTTP %s); response contents suppressed.' % e.code) from None
    if not 2 <= len(raw) <= 44100 * 2 * 120 or len(raw) % 2:
        raise PackError('Invalid provider PCM response.')
    output = io.BytesIO()
    with wave.open(output, 'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(44100); wav.writeframes(raw)
    data = output.getvalue()
    audio_info(data, 44100)
    return data, request_id


def atomically_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    for p in [path, *path.parents]:
        if p.is_symlink():
            raise PackError('Refusing linked output paths.')
    fd, tmp = tempfile.mkstemp(prefix='.voice-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data); handle.flush(); os.fsync(handle.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def convert_audio(data, rate):
    if rate not in RATES:
        raise PackError('Unsupported prompt sample rate.')
    result = subprocess.run(['ffmpeg','-v','error','-nostdin','-i','pipe:0','-ac','1','-ar',str(rate),
         '-af','loudnorm=I=-20:TP=-3:LRA=7','-c:a','pcm_s16le','-f','wav','pipe:1'],
         input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise PackError('Audio conversion failed; diagnostic output suppressed.')
    with wave.open(io.BytesIO(result.stdout),'rb') as wav:
        pcm = wav.readframes(wav.getnframes())
    output = io.BytesIO()
    with wave.open(output,'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(rate); wav.writeframes(pcm)
    data = output.getvalue()
    audio_info(data,rate)
    return data


def tenant_greeting(c, name, destination, key):
    # Only the administrator-approved tenant display name goes to the provider.
    # IDs, CLI values and caller-entered digits must never enter this interface.
    if not isinstance(name,str) or not re.fullmatch(r"[\w .,'&()\-]{1,100}",name,re.UNICODE) or not name.strip():
        raise PackError('Enter a plain tenant display name of at most 100 characters.')
    text = 'Hello, this is '+name.strip()+' calling you back. You may now authenticate by entering your South African ID Number and press hash.'
    raw, _ = synthesis(c,text,key)
    data = convert_audio(raw,8000)
    if Path(destination).exists():
        raise PackError('An existing greeting cannot be replaced by this build command.')
    atomically_write(destination,data)
    print(json.dumps({'version':c['version'],'voice_id':c['voice_id'],'greeting':audio_info(data,8000)}),flush=True)


def generation_plan(c):
    unique = {p.get('spoken_text', p['text']) for p in c['prompts']}
    return {'version': c['version'], 'voice_id': c['voice_id'], 'scripts': len(c['prompts']),
        'targets': sum(len(p['targets']) for p in c['prompts']), 'unique_requests': len(unique),
        'text_characters': sum(map(len, unique)), 'activated': False}


def generate(c, output, cache, key, workers):
    output, cache = Path(output), Path(cache)
    if output.exists() and (output/'pack.json').exists():
        raise PackError('A completed pack is immutable; choose a new empty output directory.')
    voice = request_json('/voices/' + c['voice_id'], key)
    labels = voice.get('sharing', {}).get('labels', {}) | voice.get('labels', {})
    expected_name = c.get('voice_name', '')
    expected_labels = c.get('voice_labels', {'accent': 'british'})
    if (voice.get('voice_id') != c['voice_id'] or voice.get('name') != expected_name
            or any(labels.get(name) != value for name, value in expected_labels.items())):
        raise PackError('The live provider voice does not match the requested catalogue identity.')
    sub = request_json('/user/subscription', key)
    if sub.get('status') != 'active' or sub.get('tier') not in {'pro', 'scale', 'business', 'enterprise'}:
        raise PackError('An active paid plan supporting 44.1 kHz PCM is required.')
    if sub.get('character_limit', 0)-sub.get('character_count', 0) < generation_plan(c)['text_characters']:
        raise PackError('Insufficient included character balance; automatic purchases are not enabled by this tool.')
    cache.mkdir(parents=True, exist_ok=True)
    cache.chmod(0o700)
    groups = {}
    for p in c['prompts']:
        groups.setdefault(p.get('spoken_text', p['text']), []).append(p)
    results, lock, finished = {}, threading.Lock(), 0
    def one(item):
        nonlocal finished
        text, prompts = item
        binding = {k: c[k] for k in ['voice_id', 'model_id', 'voice_settings', 'provider_output_format']}
        binding['text'] = text; binding['seed'] = 101
        ident = digest(canonical(binding))
        master, meta = cache/(ident+'.wav'), cache/(ident+'.json')
        if master.exists() and meta.exists():
            metadata = json.loads(meta.read_text(encoding='utf-8')); data = master.read_bytes()
            if metadata.get('binding_sha256') != ident or metadata.get('master_sha256') != digest(data):
                raise PackError('The existing generation cache is inconsistent.')
            audio_info(data, 44100)
        else:
            data, request_id = synthesis(c, text, key)
            metadata = {'binding_sha256': ident, 'master_sha256': digest(data), 'request_id': request_id}
            atomically_write(master, data); atomically_write(meta, canonical(metadata))
        for rate in {t['rate'] for p in prompts for t in p['targets']}:
            converted = convert_audio(data,rate); stats = audio_info(converted, rate)
            for prompt in prompts:
                for target in prompt['targets']:
                    if target['rate'] != rate:
                        continue
                    path = safe_file(output/'files', target['path'])
                    atomically_write(path, converted)
                    with lock:
                        results[target['path']] = stats | {'prompt_id': prompt['id'],
                            'synthesis_binding_sha256': ident, 'provider_master_sha256': metadata['master_sha256']}
        with lock:
            finished += 1
            if finished % 50 == 0 or finished == len(groups):
                print(json.dumps({'generated_requests':finished,'total_requests':len(groups),'files':len(results)}),flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        list(executor.map(one, groups.items()))
    license_file = DEFAULT_CATALOG.with_name('LICENSE-FreeSWITCH.txt')
    pack = generation_plan(c) | {'schema':1,'catalog_sha256':digest(canonical(c)), 'provider':c['provider'],
        'locale':c['locale'],'model_id':c['model_id'],
        'generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'license_sha256':digest(license_file.read_bytes()),
        'audio_processing':'ffmpeg loudnorm I=-20:TP=-3:LRA=7; mono signed 16-bit PCM; finite WAV headers',
        'files':dict(sorted(results.items()))}
    atomically_write(output/'catalog.json', canonical(c))
    atomically_write(output/'LICENSE-FreeSWITCH.txt', license_file.read_bytes())
    atomically_write(output/'pack.json', canonical(pack))
    verify(c, output)
    return pack


def verify(c, root):
    root = Path(root)
    for p in [root, *root.parents]:
        if p.is_symlink():
            raise PackError('A pack root cannot be a symbolic link.')
    pack = json.loads((root/'pack.json').read_text(encoding='utf-8'))
    for key in ['version','voice_id','provider','locale','model_id']:
        if pack.get(key) != c.get(key):
            raise PackError('Voice pack identity does not match its catalogue.')
    if pack.get('schema') != 1 or pack.get('catalog_sha256') != digest(canonical(c)):
        raise PackError('Voice catalogue binding is invalid.')
    expected = {t['path']: (p,t) for p in c['prompts'] for t in p['targets']}
    if set(pack.get('files', {})) != set(expected):
        raise PackError('Voice pack is incomplete or has unlisted entries.')
    actual = set()
    for path in (root/'files').rglob('*'):
        if path.is_symlink():
            raise PackError('Voice pack contains a symbolic link.')
        if path.is_file():
            actual.add(path.relative_to(root/'files').as_posix())
    if actual != set(expected):
        raise PackError('Voice audio inventory is incomplete or has unknown files.')
    for name, (prompt,target) in expected.items():
        observed = audio_info(safe_file(root/'files',name).read_bytes(), target['rate'])
        recorded = pack['files'][name]
        if observed != {k: recorded.get(k) for k in observed} or recorded.get('prompt_id') != prompt['id']:
            raise PackError('Voice audio differs from its sealed manifest.')
        binding = {k:c[k] for k in ['voice_id','model_id','voice_settings','provider_output_format']}
        binding.update(text=prompt.get('spoken_text',prompt['text']),seed=101)
        if recorded.get('synthesis_binding_sha256') != digest(canonical(binding)) or not HASH.fullmatch(recorded.get('provider_master_sha256','')):
            raise PackError('The audio generation identity does not match the script and voice.')
    if json.loads((root/'catalog.json').read_text(encoding='utf-8')) != c:
        raise PackError('The embedded voice catalogue has changed.')
    if digest((root/'LICENSE-FreeSWITCH.txt').read_bytes()) != pack.get('license_sha256'):
        raise PackError('The original component licence has changed.')
    extras = {p.name for p in root.iterdir()}
    if extras != {'files','catalog.json','LICENSE-FreeSWITCH.txt','pack.json'}:
        raise PackError('Unknown files are present in the voice package.')
    print(json.dumps({'verified':len(expected),'version':c['version'],'activated':False}),flush=True)
    return pack


def archive(c, root, destination):
    verify(c, root)
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise PackError('An existing voice archive cannot be replaced.')
    if any(parent.is_symlink() for parent in destination.parents):
        raise PackError('A voice archive output parent cannot be a symbolic link.')
    with tarfile.open(destination, 'w:gz', compresslevel=9) as tar:
        for path in sorted(Path(root).rglob('*')):
            if path.is_file():
                tar.add(path, arcname=path.relative_to(root).as_posix(), recursive=False)
    print(json.dumps({'archive':destination.name,'sha256':digest(destination.read_bytes()),'bytes':destination.stat().st_size}),flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog',type=Path,default=DEFAULT_CATALOG)
    sub = parser.add_subparsers(dest='command',required=True)
    sub.add_parser('plan')
    gen = sub.add_parser('generate')
    gen.add_argument('--output',type=Path,required=True)
    gen.add_argument('--cache',type=Path,required=True)
    gen.add_argument('--env-file',type=Path)
    gen.add_argument('--workers',type=int,choices=range(1,6),default=3)
    gen.add_argument('--execute',action='store_true',help='Generate using the configured paid ElevenLabs account.')
    check = sub.add_parser('verify'); check.add_argument('--pack',type=Path,required=True)
    bundle = sub.add_parser('archive'); bundle.add_argument('--pack',type=Path,required=True); bundle.add_argument('--output',type=Path,required=True)
    greeting = sub.add_parser('tenant-greeting')
    greeting.add_argument('--tenant-name',required=True)
    greeting.add_argument('--output',type=Path,required=True)
    greeting.add_argument('--env-file',type=Path)
    args = parser.parse_args(); c = load_catalog(args.catalog)
    if args.command == 'plan' or (args.command == 'generate' and not args.execute):
        print(json.dumps(generation_plan(c),indent=2))
    elif args.command == 'generate':
        generate(c,args.output,args.cache,api_key(args.env_file),args.workers)
    elif args.command == 'verify':
        verify(c,args.pack)
    elif args.command == 'archive':
        archive(c,args.pack,args.output)
    elif args.command == 'tenant-greeting':
        tenant_greeting(c,args.tenant_name,args.output,api_key(args.env_file))


if __name__ == '__main__':
    try:
        main()
    except (PackError,OSError,ValueError,KeyError) as error:
        # Network exception strings may contain request URLs. Never emit headers,
        # response bodies, source text, tenant information or API credentials.
        print('Voice operation stopped: '+(str(error) if isinstance(error,PackError) else type(error).__name__),file=sys.stderr)
        sys.exit(1)
