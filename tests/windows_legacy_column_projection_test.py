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
PROJECTION = next(n for n in NODES if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='old_projection'for t in n.targets))
GUARD = next(n for n in NODES if isinstance(n,ast.If) and ast.unparse(n.test)=="old_projection != previous['columns']")
EXPECTED = next(n for n in NODES if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='expected'for t in n.targets))
PROGRAM = compile(ast.Module(body=[PROJECTION,GUARD],type_ignores=[]),'actual-inline-column-comparator','exec')

class Columns(unittest.TestCase):
    def setUp(self):
        self.expected=ast.literal_eval(EXPECTED.value)
        self.before=[{'table_name':'v_pbx_templates','column_name':'template_uuid','ordinal_position':1,'data_type':'uuid'},
                     {'table_name':'original_view','column_name':'template_uuid','ordinal_position':1,'data_type':'uuid'}]
        self.after=copy.deepcopy(self.before)+[{'table_name':name,'column_name':'id','ordinal_position':1,'data_type':'uuid'}for name in sorted(self.expected)]+[
            {'table_name':'v_pbx_templates','column_name':'api_enabled','ordinal_position':2,'data_type':'boolean'}]
    def run_comparator(self,rows):
        scope={'columns':rows,'previous':{'columns':self.before},'expected':self.expected,'old_names':{'v_pbx_templates'}}
        exec(PROGRAM,scope)
        return scope['old_projection']
    def test_exact_source_tables_removed_and_original_view_preserved(self):
        self.assertEqual(len(self.expected),8)
        self.assertEqual(self.run_comparator(self.after),self.before)
    def test_changed_original_view_column_refused(self):
        rows=copy.deepcopy(self.after);rows[1]['data_type']='text'
        with self.assertRaises(RuntimeError):self.run_comparator(rows)
    def test_removed_original_view_refused(self):
        with self.assertRaises(RuntimeError):self.run_comparator([c for c in self.after if c['table_name']!='original_view'])
    def test_unexpected_new_view_refused(self):
        with self.assertRaises(RuntimeError):self.run_comparator(self.after+[{'table_name':'unknown_view','column_name':'id','ordinal_position':1,'data_type':'uuid'}])
    def test_unexpected_old_table_column_refused(self):
        with self.assertRaises(RuntimeError):self.run_comparator(self.after+[{'table_name':'v_pbx_templates','column_name':'unexpected','ordinal_position':3,'data_type':'text'}])
    def test_original_base_column_change_refused(self):
        rows=copy.deepcopy(self.after);rows[0]['ordinal_position']=2
        with self.assertRaises(RuntimeError):self.run_comparator(rows)

if __name__=='__main__':unittest.main()
