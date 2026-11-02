#!/usr/bin/env python3
"""Exercise the actual inline cross-version column comparator, including views.

Synthetic metadata only; actual PostgreSQL source-component controls and native
Windows installation acceptance are separately retained.
"""
import ast
import copy
from pathlib import Path
import unittest

SOURCE = Path(__file__).with_name('windows-upgrade-acceptance.ps1')
CODE = SOURCE.read_text().split("$code=@'\n",1)[1].split("\n'@",1)[0]
TREE = ast.parse(CODE)
BLOCK = next(n for n in TREE.body if isinstance(n,ast.If) and ast.unparse(n.test)=="action in ('legacy-before', 'legacy-after')")
NODES = list(ast.walk(BLOCK))
PROJECTIONS = [n for n in NODES if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='old_projection'for t in n.targets)]
QR_PROJECTION = next(n for n in NODES if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='qr_projection'for t in n.targets))
GUARD = next(n for n in NODES if isinstance(n,ast.If) and ast.unparse(n.test)=="old_projection != previous['columns']")
EXPECTED = next(n for n in NODES if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='expected'for t in n.targets))
HELPERS = [n for n in TREE.body if isinstance(n,ast.FunctionDef) and n.name in {'_require','_index','expected_qr_columns','project_legacy_columns'}]
CONSTANTS = [n for n in TREE.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id in {'PUBLIC21_MOBILE_SQL_SHA256','CANDIDATE_MOBILE_SQL_SHA256','COLUMN_KEYS','NEW_TABLES'} for t in n.targets)]
PROGRAM = compile(ast.Module(body=[*CONSTANTS,*HELPERS,*PROJECTIONS[:1],QR_PROJECTION,*PROJECTIONS[1:],GUARD],type_ignores=[]),'actual-inline-column-comparator','exec')
QR_SQL = (SOURCE.parent.parent/'app/pbx_mobile/resources/install.sql').read_bytes()

class Columns(unittest.TestCase):
    def setUp(self):
        self.expected=ast.literal_eval(EXPECTED.value)
        def column(table,name,ordinal,data_type='uuid',udt_name='uuid',nullable='YES'):
            return {'table_name':table,'column_name':name,'ordinal_position':ordinal,'data_type':data_type,'udt_name':udt_name,'is_nullable':nullable,'column_default':None}
        self.before=sorted([column('v_pbx_templates','template_uuid',1),
                     column('original_view','template_uuid',1),
                     column('v_pbx_mobile_enrollments','enrollment_uuid',1),
                     column('v_pbx_mobile_enrollments','extension_uuid',2),
                     column('v_pbx_mobile_enrollments','expires_at',3,'timestamp with time zone','timestamptz','NO'),
                     column('v_pbx_mobile_welcome','expires_at',1,'timestamp with time zone','timestamptz','NO')],key=lambda c:(c['table_name'],c['ordinal_position']))
        self.after=copy.deepcopy(self.before)
        for c in self.after:
            if c['table_name'] in ('v_pbx_mobile_enrollments','v_pbx_mobile_welcome') and c['column_name']=='expires_at':c['is_nullable']='YES'
        self.after += [column('v_pbx_mobile_enrollments','code_ciphertext',4,'text','text'),column('v_pbx_mobile_enrollments','server_origin',5,'text','text'),column('v_pbx_mobile_enrollments','revoked_at',6,'timestamp with time zone','timestamptz')]
        self.after += [column(name,'id',1)for name in sorted(self.expected)]+[column('v_pbx_templates','api_enabled',2,'boolean','bool')]
        self.after.sort(key=lambda c:(c['table_name'],c['ordinal_position']))
    def run_comparator(self,rows):
        scope={'columns':rows,'previous':{'columns':self.before},'expected':self.expected,'old_names':{'v_pbx_templates'},'qr_sql':QR_SQL,'copy':copy,'hashlib':__import__('hashlib')}
        exec(PROGRAM,scope)
        return scope['old_projection']
    def test_exact_source_tables_removed_and_original_view_preserved(self):
        self.assertEqual(len(self.expected),8)
        self.assertEqual(self.run_comparator(self.after),self.before)
    def test_changed_original_view_column_refused(self):
        rows=copy.deepcopy(self.after);next(c for c in rows if c['table_name']=='original_view')['data_type']='text'
        with self.assertRaises(RuntimeError):self.run_comparator(rows)
    def test_removed_original_view_refused(self):
        with self.assertRaises(RuntimeError):self.run_comparator([c for c in self.after if c['table_name']!='original_view'])
    def test_unexpected_new_view_refused(self):
        with self.assertRaises(RuntimeError):self.run_comparator(self.after+[{'table_name':'unknown_view','column_name':'id','ordinal_position':1,'data_type':'uuid','udt_name':'uuid','is_nullable':'YES','column_default':None}])
    def test_unexpected_old_table_column_refused(self):
        with self.assertRaises(RuntimeError):self.run_comparator(self.after+[{'table_name':'v_pbx_templates','column_name':'unexpected','ordinal_position':3,'data_type':'text','udt_name':'text','is_nullable':'YES','column_default':None}])
    def test_original_base_column_change_refused(self):
        rows=copy.deepcopy(self.after);next(c for c in rows if c['table_name']=='v_pbx_templates' and c['column_name']=='template_uuid')['ordinal_position']=2
        with self.assertRaises(RuntimeError):self.run_comparator(rows)

if __name__=='__main__':unittest.main()
