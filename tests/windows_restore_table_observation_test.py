#!/usr/bin/env python3
"""Actual restore comparison/projection controls over fictional snapshot digests."""
import ast,contextlib,copy,importlib.util,io,json,os,unittest
from pathlib import Path
from unittest import mock
HERE=Path(__file__).resolve().parent
SOURCE=Path(os.environ.get('RESTORE_OBSERVATION_SOURCE',str(HERE/'windows-restore-qualification.py')))
spec=importlib.util.spec_from_file_location('observed_restore',SOURCE);q=importlib.util.module_from_spec(spec);spec.loader.exec_module(q)
class TableObservation(unittest.TestCase):
 def row(self,n=1,d='a'):return {'rows':n,'hmac':d*64}
 def snapshot(self,label='target-restored'):
  return {'label':label,'schema_metadata':{'schema':'same','tables':'same','columns':'same'},'target_owned':{'same':True},'all_table_values':{'v_extensions':self.row(),'v_users':self.row(),'v_pbx_backup_status':self.row()},'source_phone_tuples':'same','restore_projections':{}}
 def failure(self,a,b,mode='source-restored'):
  with self.assertRaises(ValueError) as caught:q.compare_snapshots(a,b,mode)
  self.assertEqual(caught.exception.args,('Preserved non-operational PBX records changed.',));return caught.exception
 def test_exact_equal_and_original_operational_exclusions(self):
  a=self.snapshot();b=copy.deepcopy(a);b['all_table_values']['v_pbx_backup_status']=self.row(5,'b')
  with mock.patch.object(q,'observe_restore_table_difference',side_effect=RuntimeError('Must not run')) as observer:q.compare_snapshots(a,b,'source-restored')
  observer.assert_not_called()
 def test_actual_different_known_unknown_added_removed_counts_and_privacy(self):
  a=self.snapshot();b=copy.deepcopy(a);a['all_table_values']['v_PRIVATE_customer_name']=self.row();b['all_table_values'].pop('v_users');b['all_table_values']['v_extensions']=self.row(2,'b');b['all_table_values']['v_default_settings']=self.row();b['all_table_values']['v_PRIVATE_customer_name']=self.row(1,'c');saved=copy.deepcopy((a,b))
  error=self.failure(a,b);record=q.restore_table_failure_fields(error)['table_comparison']
  self.assertEqual(record,dict(schema=1,mode='source-restored',label='target-restored',before_tables=3,after_tables=3,changed_tables=4,known_tables=['v_default_settings','v_extensions','v_users'],other_tables=1,row_count_changed=1,digest_changed=2,missing_before=1,missing_after=1))
  self.assertEqual((a,b),saved);serialized=json.dumps(record);self.assertNotIn('PRIVATE',serialized);self.assertNotIn('a'*64,serialized);self.assertNotIn('b'*64,serialized)
 def test_existing_health_pending_projection_remains_exact(self):
  a=self.snapshot();b=copy.deepcopy(a);a['all_table_values']['v_pbx_phone_health_recoveries']=self.row(5);a['health_recovery_restore']={'rows':5,'pending':2,'hmac':'b'*64};b['all_table_values']['v_pbx_phone_health_recoveries']=self.row(5,'b')
  q.compare_snapshots(a,b,'source-restored');b['all_table_values']['v_pbx_phone_health_recoveries']=self.row(5,'c');error=self.failure(a,b);self.assertEqual(error.table_comparison['known_tables'],['v_pbx_phone_health_recoveries']);self.assertEqual(error.table_comparison['digest_changed'],1)
 def test_failure_observer_error_cannot_replace_primary(self):
  a=self.snapshot();b=copy.deepcopy(a);b['all_table_values']['v_extensions']=self.row(2)
  with mock.patch.object(q,'observe_restore_table_difference',side_effect=RuntimeError('PRIVATE observer error')):error=self.failure(a,b)
  self.assertFalse(hasattr(error,'table_comparison'))
 def test_fixed_mode_label_combinations_and_malformed_snapshot_still_refuse(self):
  for mode,label in [('factory-recovery','target-wrongpass'),('factory-recovery','target-recovered'),('source-restored','target-restored')]:
   a=self.snapshot(label);b=copy.deepcopy(a);b['all_table_values']['v_extensions']=self.row(2);error=self.failure(a,b,mode);self.assertEqual((error.table_comparison['mode'],error.table_comparison['label']),(mode,label))
  for label in ('PRIVATE',True,None,[],{}):
   a=self.snapshot(label);b=copy.deepcopy(a);b['all_table_values']['v_extensions']=self.row(2);error=self.failure(a,b);self.assertFalse(hasattr(error,'table_comparison'))
  a=self.snapshot();b=copy.deepcopy(a);b['all_table_values']['v_extensions']={'rows':'PRIVATE','hmac':'bad'};error=self.failure(a,b);self.assertFalse(hasattr(error,'table_comparison'))
 def test_projection_refuses_unknown_fields_types_counts_names_order_and_aliases(self):
  a=self.snapshot();b=copy.deepcopy(a);b['all_table_values']['v_extensions']=self.row(2,'b');good=self.failure(a,b).table_comparison
  for key in good:
   bad=copy.deepcopy(good);bad.pop(key);self.assertEqual(q.restore_table_observation_fields(bad),{})
  for key in ('schema','before_tables','after_tables','changed_tables','other_tables','row_count_changed','digest_changed','missing_before','missing_after'):
   for value in (True,None,'1',-1,4097,1.5):
    bad=copy.deepcopy(good);bad[key]=value;self.assertEqual(q.restore_table_observation_fields(bad),{})
  for key,value in [('unknown','PRIVATE'),('known_tables',['v_PRIVATE']),('known_tables',['v_extensions','v_extensions']),('known_tables',['v_users','v_extensions']),('known_tables',('v_extensions',)),('mode','factory-recovery'),('label','target-wrongpass'),('changed_tables',0),('other_tables',1),('missing_before',1),('missing_after',2)]:
   bad=copy.deepcopy(good);bad[key]=value;self.assertEqual(q.restore_table_observation_fields(bad),{})
  observed=q.restore_table_observation_fields(good);observed['known_tables'].append('v_users');self.assertEqual(good['known_tables'],['v_extensions'])
  wrong=RuntimeError('PRIVATE');wrong.table_comparison=good;self.assertEqual(q.restore_table_failure_fields(wrong),{})
 def test_actual_final_error_json_contains_only_closed_fields(self):
  a=self.snapshot();b=copy.deepcopy(a);b['all_table_values']['v_extensions']=self.row(2);error=self.failure(a,b);error.private='PRIVATE SQL password'
  final=ast.parse(SOURCE.read_text()).body[-1];program=compile(ast.Module(body=[final],type_ignores=[]),str(SOURCE),'exec')
  def fail():
   try:q.compare_snapshots(a,b,'source-restored')
   except ValueError as primary:primary.private='PRIVATE SQL password';raise
  namespace=q.__dict__.copy()|{'__name__':'__main__','main':fail};out=io.StringIO()
  with contextlib.redirect_stdout(out),self.assertRaises(SystemExit) as stopped:exec(program,namespace)
  self.assertEqual(stopped.exception.code,1);j=json.loads(out.getvalue());self.assertEqual(set(j),{'state','error_type','active_case','source_basename','source_line','table_comparison'});self.assertEqual(j['table_comparison'],error.table_comparison);self.assertNotIn('PRIVATE',out.getvalue());self.assertEqual(j['source_basename'],'windows-restore-qualification.py')
 def test_input_limit_keeps_original_refusal_and_no_arbitrary_names(self):
  a=self.snapshot();b=copy.deepcopy(a);a['all_table_values']={f'v_PRIVATE_{i}':self.row() for i in range(4097)};b['all_table_values']={};error=self.failure(a,b);self.assertFalse(hasattr(error,'table_comparison'))
if __name__=='__main__':unittest.main()
