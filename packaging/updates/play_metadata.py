"""Validate an operator-reviewed, fully published Google Play production release."""
import datetime as dt
import re
from verify_feed import timestamp, version

FIELDS = {'status', 'track', 'rollout', 'package_id', 'version', 'version_code',
          'minimum_server_version', 'min_sdk', 'published_at'}


def validate(value, feed_version, feed_published, now):
    if not isinstance(value, dict) or set(value) != FIELDS:
        raise ValueError('Play publication metadata must contain exactly the documented fields.')
    if (value['status'], value['track'], value['rollout'], value['package_id']) != (
            'published', 'production', 'complete', 'com.openweb.pbx'):
        raise ValueError('Only an approved, fully rolled-out production Play release may be announced.')
    for field in ('version', 'minimum_server_version'):
        if not isinstance(value[field], str) or not re.fullmatch(r'[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}', value[field]):
            raise ValueError('Play versions must be three numeric components of at most six digits.')
        version(value[field])
    if version(value['version']) > version(feed_version):
        raise ValueError('A Play publication cannot be newer than its signed release feed.')
    if type(value['version_code']) is not int or not 1 <= value['version_code'] <= 2147483647:
        raise ValueError('The published Play version code is invalid.')
    if type(value['min_sdk']) is not int or not 28 <= value['min_sdk'] <= 100:
        raise ValueError('The published Play minimum Android version is invalid.')
    published = timestamp(value['published_at'])
    if published < dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc) or published > timestamp(feed_published) or published > now + dt.timedelta(minutes=5):
        raise ValueError('Play publication must already exist when the release feed is published.')
    return dict(value)
