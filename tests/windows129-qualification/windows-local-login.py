from html.parser import HTMLParser
from http.cookiejar import CookieJar
import json
from pathlib import Path
import socket
import ssl
import sys
from urllib.error import HTTPError
from urllib.parse import urlencode,urljoin,urlsplit
import urllib.request

origin, file = sys.argv[1:]
parsed = urlsplit(origin)
assert parsed.hostname == 'openwebpbx-qa129.invalid' and parsed.port == 18443

class LoginForm(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.forms = []
        self.current = None
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == 'form':
            self.current = {}
            self.forms.append((values.get('action', ''), self.current))
        elif tag == 'input' and self.current is not None and values.get('name'):
            if values.get('type') in {'checkbox','radio','submit'} and 'checked' not in values:
                return
            self.current[values['name']] = values.get('value', '')

    def handle_endtag(self, tag):
        if tag == 'form':
            self.current = None

class LocalRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        assert urlsplit(newurl).netloc == parsed.netloc and urlsplit(newurl).scheme == 'https'
        return super().redirect_request(req,fp,code,msg,headers,newurl)

lookup=socket.getaddrinfo

def local_lookup(host, port, *args, **kwargs):
    assert host == parsed.hostname and port == parsed.port
    return lookup('127.0.0.1',port,*args,**kwargs)

socket.getaddrinfo=local_lookup
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(CookieJar()),
    urllib.request.HTTPSHandler(context=ssl.create_default_context()),LocalRedirect())

def request(path, values=None):
    url=urljoin(origin+'/',path)
    assert urlsplit(url).netloc == parsed.netloc and urlsplit(url).scheme == 'https'
    try:
        response=opener.open(url,None if values is None else urlencode(values).encode(),timeout=20)
    except HTTPError as error:
        response=error
    with response:
        body=response.read(2*1024**2).decode('utf-8')
        return response.code,body

secret=json.loads(Path(file).read_text(encoding='utf-8-sig'))
status,login=request('/login.php')
assert status == 200
forms=[(action,fields) for action,fields in LoginForm(login).forms if {'username','password'} <= set(fields)]
assert len(forms) == 1
action,fields=forms[0]
status,_=request(action or '/login.php',fields | {'username':secret['email'],'password':secret['password']})
assert status in {200,403}
status,page=request('/app/pbx_updates/')
assert status == 200 and 'Software Updates' in page and 'data-update-status' in page
status,body=request('/app/pbx_updates/status.php')
result=json.loads(body)
assert status == 200 and result['installed_version'] == '1.0.29' and 'server_controls' in result
print('Trusted HTTPS admission, ordinary authenticated Software Updates and installed release verified.')
