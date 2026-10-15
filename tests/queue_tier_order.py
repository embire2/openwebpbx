#!/usr/bin/env python3
"""Actual Lua commands -> pinned native C parser/SQL and PHP priority parity.

Only temporary local C executables/SQLite databases are used; no PBX is started.
"""
import argparse
import ast
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--native-source', type=Path, required=True,
                    help='Pinned 6,214-input FreeSWITCH mod_callcenter.c')
args = parser.parse_args()
source = args.native_source.read_text()
assert hashlib.sha256(args.native_source.read_bytes()).hexdigest() == '35aea35357a49c02a44c61330206407546178ddd53f1b478f8c70f3b235c35d5'


def cstrings(value):
    return ''.join(ast.literal_eval(s) for s in re.findall(r'"(?:\\.|[^"\\])*"', value))


def statements(start_marker, end_marker, offset=0):
    start = source.index(start_marker, offset)
    return source[start:source.index(end_marker, start)]


add_parser = statements('int i_level=1, i_position=1;', '\n\n\t\t\t\tswitch(cc_tier_add')
tier_section = source.index('} else if (section && !strcasecmp(section, "tier"))')
set_section = source.index('} else if (action && !strcasecmp(action, "set"))', tier_section)
set_parser = statements('const char *key = argv[0 + initial_argc];', '\n\n\t\t\t\tswitch(cc_tier_update', set_section)
update_section = source.index('cc_status_t cc_tier_update(')
updates = {}
for key in ('level', 'position'):
    branch = source.index('} else if (!strcasecmp(key, "' + key + '"))', update_section)
    updates[key] = statements('sql = switch_mprintf(', '\n\n\t\tresult = CC_STATUS_SUCCESS;', branch)
agent_schema = cstrings(source.split('static char agents_sql[] =', 1)[1].split('static char tiers_sql[] =', 1)[0])
tier_schema = cstrings(source.split('static char tiers_sql[] =', 1)[1].split('static switch_xml_config_int_options_t', 1)[0])
member_callback = source.index('static int members_callback(')
top_down = source.index('if (!strcasecmp(queue->strategy, "top-down"))', member_callback)
query = cstrings(statements('sql = switch_mprintf("SELECT instance_id', ',\n\t\t\t\tqueue_name,', top_down))
realm = 'fixture.example.invalid'
queue = '8190@' + realm
values = iter([queue, 'Available', 'On Break', 'Available (On Demand)', 0, 0,
               queue, 'Available', 'On Break', 'Available (On Demand)', 0])
query = re.sub(r'%[qd]', lambda _: str(next(values)), query)

lua = subprocess.run(['lua5.4', 'tests/queue_runtime.lua'], cwd=ROOT, capture_output=True, text=True, check=True)
commands = {}
repairs = []
for line in lua.stdout.splitlines():
    if line.startswith('EMIT|'):
        _, label, command = line.split('|', 2)
        commands.setdefault(label, []).append(command)
    elif line.startswith('REPAIR|'):
        repairs.append(line.split('|', 1)[1])
assert len(commands['fresh']) == 2 and len(repairs) == 3

with tempfile.TemporaryDirectory(prefix='openweb-queue-tier-order-') as folder:
    work = Path(folder)
    c = work / 'native-tier.c'
    exe = work / 'native-tier'
    c.write_text(r'''
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>
#define zstr(s) (!(s)||!*(s))
#define switch_mprintf sqlite3_mprintf
#define switch_safe_free(s) do {sqlite3_free(s);s=NULL;} while(0)
static sqlite3 *db;
static void cc_execute_sql(void *unused,const char *sql,void *other){(void)unused;(void)other;assert(sqlite3_exec(db,sql,NULL,NULL,NULL)==SQLITE_OK);}
int main(int argc,char **raw){assert(argc>=7);const char **argv=(const char **)(raw+1);int initial_argc=2;
 if(!strcmp(argv[1],"add")){
''' + add_parser + r'''
  printf("%s|%s|%d|%d\n",queue_name,agent,i_level,i_position);
 }else{assert(!strcmp(argv[1],"set"));
''' + set_parser + r'''
  assert(sqlite3_open(getenv("QUEUE_TIER_TEST_DB"),&db)==SQLITE_OK);char *sql=NULL;
  if(!strcmp(key,"level")){
''' + updates['level'] + r'''
  }else{assert(!strcmp(key,"position"));
''' + updates['position'] + r'''
  }assert(sqlite3_close(db)==SQLITE_OK);
 }return 0;
}
''')
    subprocess.run(['cc', '-std=c99', '-Wall', '-Wextra', '-Werror', str(c), '-lsqlite3', '-o', str(exe)], check=True)

    def native_parse(command):
        result = subprocess.check_output([str(exe), *command.split()], text=True).strip().split('|')
        return {'queue': result[0], 'agent': result[1], 'level': int(result[2]), 'position': int(result[3])}

    current = [native_parse(command) for command in commands['fresh']]
    old = []
    for command in commands['fresh']:
        words = command.split()
        words.insert(4, 'Ready')  # Exact old emitter: Ready 1 <position>.
        old.append(native_parse(' '.join(words)))
    assert [(row['level'], row['position']) for row in old] == [(0, 1), (0, 1)]
    assert [(row['level'], row['position']) for row in current] == [(1, 1), (1, 2)]
    selected = {}
    for label, rows in [('old', old), ('current', current)]:
        selected[label] = []
        for reverse in (False, True):
            db = sqlite3.connect(':memory:')
            db.executescript(agent_schema + tier_schema)
            identities = [row['agent'] for row in rows]
            if reverse:
                identities.reverse()
            numbers = {}
            for index, row in enumerate(rows):
                ident = identities[index]
                numbers[ident] = '8101' if index == 0 else '8102'
                db.execute('insert into agents(name,instance_id,type,contact,status,state) values(?,?,?,?,?,?)',
                           (ident, 'single_box', 'callback', 'user/' + numbers[ident] + '@' + realm, 'Available', 'Waiting'))
                db.execute('insert into tiers(queue,agent,state,level,position) values(?,?,?,?,?)',
                           (row['queue'], ident, 'Ready', row['level'], row['position']))
            db.execute('pragma query_only=ON')
            ordered = [numbers[row[1]] for row in db.execute(query)]
            assert len(ordered) == 2
            selected[label].append(ordered)
            db.close()
    assert {order[0] for order in selected['old']} == {'8101', '8102'}
    assert selected['current'] == [['8101', '8102'], ['8101', '8102']]

    # Execute the ACTUAL native tier-set parser and scoped UPDATE statements on
    # the ACTUAL Lua repair commands. Every other tier/agent column must survive.
    file = work / 'repair.db'
    db = sqlite3.connect(file)
    db.executescript(agent_schema + tier_schema)
    first, second = (row['agent'] for row in current)
    foreign = '22222222-2222-4222-8222-222222222222'
    for ident, status, state in [(first, 'Available', 'In a queue call'), (second, 'On Break', 'Receiving'), (foreign, 'Available', 'Waiting')]:
        db.execute('insert into agents(name,instance_id,status,state,contact,calls_answered,talk_time,ready_time) values(?,?,?,?,?,?,?,?)',
                   (ident, 'single_box', status, state, 'private-preserved-contact', 23, 876, 234))
    original = [(queue, first, 'Active Inbound', 0, 1), (queue, second, 'Offering', 0, 1),
                ('8191@foreign.invalid', first, 'Standby', 0, 1), (queue, foreign, 'Ready', 0, 1)]
    db.executemany('insert into tiers(queue,agent,state,level,position) values(?,?,?,?,?)', original)
    agents_before = db.execute('select * from agents order by name').fetchall()
    db.commit()
    for command in repairs:
        subprocess.run([str(exe), *command.split()], env=os.environ | {'QUEUE_TIER_TEST_DB': str(file)}, check=True)
    expected = [(queue, first, 'Active Inbound', 1, 1), (queue, second, 'Offering', 3, 2), *original[2:]]
    assert sorted(db.execute('select * from tiers')) == sorted(expected)
    assert db.execute('select * from agents order by name').fetchall() == agents_before
    db.close()

    # Evaluate the exact authoritative PHP insertion expression, rather than
    # duplicating an assumed cast in a second Python implementation.
    php = (ROOT / 'resources/classes/pbx_admin.php').read_text()
    expression = re.search(r"'tier_level'=>(max\(1,\(int\)\(\$m\['skill'\]\?\?0\)\+1\))", php).group(1)
    skills = {'missing': None, 'empty': '', 'negative': '-4', 'zero': '0', 'two': '2', 'upper': '9', 'imported': '14',
              'decimal': '2.9', 'negative_fraction': '-0.2', 'negative_decimal': '-2.9', 'small_fraction': '.2',
              'nonnumeric': 'unassigned', 'numeric_prefix': '2.9imported', 'scientific': '1.e2 imported', 'hex_text': '0x10'}
    script = '$out=[];foreach(json_decode(stream_get_contents(STDIN),true,512,JSON_THROW_ON_ERROR) as $name=>$skill){$m=["skill"=>$skill];$out[$name]=' + expression + ';}echo json_encode($out,JSON_THROW_ON_ERROR);'
    php_levels = json.loads(subprocess.check_output(['php', '-r', script], input=json.dumps(skills), text=True))
    assert set(php_levels) == {name.removeprefix('skill-') for name in commands if name.startswith('skill-')}
    for name, level in php_levels.items():
        assert native_parse(commands['skill-' + name][0])['level'] == level, name

print(lua.stdout.splitlines()[-1])
print('PASS actual pinned C add/set parsers, SQLite schemas/selection/scoped repairs, old reversed-identity control and both corrected orders, and 15 actual PHP skill-level parity cases; no PBX contacted')
