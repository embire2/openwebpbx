"""One original Path.read_text call; closed synthetic result only, no raw data."""
import json,os,sys
from pathlib import Path
if os.name!='nt' or os.environ.get('GITHUB_ACTIONS')!='true' or os.environ.get('RUNNER_ENVIRONMENT')!='github-hosted' or os.environ.get('GITHUB_REPOSITORY')!='embire2/openwebpbx':raise SystemExit('Owned Windows component only.')
path=Path(sys.argv[1]);result={'schema':1,'state':'other','winerror_category':'none','exact_synthetic_json':False}
try:
 value=json.loads(path.read_text(encoding='utf-8-sig'));result.update(state='read_ok',exact_synthetic_json=value=={'schema':1,'synthetic':True})
except PermissionError as error:result.update(state='permission_error',winerror_category={5:'access_denied',32:'sharing_violation',33:'lock_violation'}.get(getattr(error,'winerror',None),'other'))
except json.JSONDecodeError:result['state']='invalid_json'
except Exception:result['state']='other'
print(json.dumps(result,separators=(',',':')))
