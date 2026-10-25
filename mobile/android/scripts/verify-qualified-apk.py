#!/usr/bin/env python3
"""Prove QA signing did not change any unsigned release payload entry.

This checks payload equality only. Android's apksigner separately verifies the
qualification signature; production signing and its identity stay outside CI.
"""
import argparse
import hashlib
import json
from pathlib import PurePosixPath
import re
import zipfile

SIGNATURE=re.compile(r'META-INF/(?:MANIFEST\.MF|[^/]+\.(?:RSA|DSA|EC|SF))\Z',re.I)

def payload(path):
    out={};seen=set();total=0
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            name=entry.filename;item=PurePosixPath(name)
            if name in seen or item.is_absolute() or '..' in item.parts or '\\' in name or str(item)!=name.rstrip('/'):
                raise ValueError('APK has duplicate or unsafe entries')
            seen.add(name)
            if entry.is_dir() or SIGNATURE.fullmatch(name):continue
            total+=entry.file_size
            if entry.file_size>512*1024*1024 or total>2*1024*1024*1024:raise ValueError('APK payload exceeds its bound')
            with archive.open(entry) as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
            out[name]={'bytes':entry.file_size,'sha256':digest}
    return out

def verify(unsigned,qualified):
    original=payload(unsigned);installed=payload(qualified)
    if not original or original!=installed:raise ValueError('Qualification signing changed the release payload')
    return {'non_signature_entries':len(original),'payload_sha256':hashlib.sha256(json.dumps(original,sort_keys=True,separators=(',',':')).encode()).hexdigest()}

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('unsigned');parser.add_argument('qualified');args=parser.parse_args()
    print(json.dumps(verify(args.unsigned,args.qualified)))
