"""Bounded backup failure metadata controls; real descriptor cases require Windows."""
import ast
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import unittest

ROOT=Path(__file__).resolve().parents[1]
MARKER='private-path-SID-descriptor-marker'


def observer():
    spec=importlib.util.spec_from_file_location('sddl_observer',ROOT/'tests/windows-backups-worker-observer.py')
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


def metadata():
    acl={key:False for key in observer().ACL_BOOLEANS}
    acl.update(before_null=False,after_null=False)
    for side in ('before','after'):
        acl.update({'revision_'+side:2,'size_'+side:48,'count_'+side:2,'unique_ace_count_'+side:2,'duplicate_ace_count_'+side:0})
    value={key:False for key in observer().DESCRIPTOR_BOOLEANS}
    value.update(file_category='config',control_flags_before=32772,control_flags_after=36868,control_flags_xor=4096,
        descriptor_revision_before=1,descriptor_revision_after=1,resource_manager_control_before=0,resource_manager_control_after=0,
        dacl=copy.deepcopy(acl),sacl=copy.deepcopy(acl))
    return {'schema':1,'report_status':'read','mismatches':[value]}


class ProjectionControls(unittest.TestCase):
    def test_exact_existing_assertion_control_delegation_and_private_metadata(self):
        source=(ROOT/'tests/windows_backups_native.py').read_text()
        original="if entry['exists']:assert b.control('acl-read',{'paths':[name]})[name]==entry['sddl'],'Native recovery changed original file ACL/owner'"
        self.assertIn(original,source)
        tree=ast.parse(source);guards=[node for node in ast.walk(tree) if isinstance(node,ast.With) and any(isinstance(item.context_expr,ast.Call) and isinstance(item.context_expr.func,ast.Attribute) and item.context_expr.func.attr=='acl_checks' for item in node.items)]
        self.assertEqual(len(guards),1);self.assertIn(original,ast.get_source_segment(source,guards[0]))
        library=observer();calls=[];results=[];name='C:/private/'+MARKER+'/config.conf';expected='O:SY'+MARKER;actual='O:BA'+MARKER
        def control(*arguments,**keywords):calls.append((arguments,keywords));return results[-1]
        def run(command,**keywords):
            self.assertEqual(Path(command[-1]).name,'windows-backup-sddl.ps1');self.assertNotIn(MARKER,' '.join(command))
            request=json.loads(keywords['input']);self.assertEqual(request['items'][0]['before'],expected);self.assertEqual(request['items'][0]['after'],actual)
            value=metadata();value['private']=MARKER;value['mismatches'][0]['sddl']=MARKER
            return json.dumps(value).encode()
        with tempfile.TemporaryDirectory() as folder:
            module=types.SimpleNamespace(tool=lambda name:'/tools/'+name,RESTORE=Path(folder),STATE=Path('C:/state'),CONFIG=Path(name),KEY=Path('C:/key'),ROOTS={},control=control,run=run,native_powershell_environment=lambda:{})
            value=library.RecoveryObservation(module,Path(folder)/'report.json',lambda:True)
            result={name:actual};results.append(result)
            with value.acl_checks({name:{'exists':True,'sddl':expected}}):
                self.assertIs(module.control('acl-read',{'paths':[name]}),result)
            self.assertIs(module.control,control);self.assertEqual(len(calls),1)
            safe=value.safe_report()['acl_observation'];self.assertTrue(safe['control_restored']);self.assertEqual(safe['mismatches'][0]['file_category'],'config');self.assertNotIn(MARKER,json.dumps(safe))
            for index in range(5):value.note_acl_mismatch(name,expected,actual)
            self.assertEqual(len(value.safe_report()['acl_observation']['mismatches']),3)

    def test_original_exceptions_results_and_observer_failures_do_not_change_assertion(self):
        library=observer();failure=RuntimeError(MARKER);calls=[]
        def control(*args,**kwargs):calls.append(args);raise failure
        with tempfile.TemporaryDirectory() as folder:
            module=types.SimpleNamespace(tool=lambda name:name,RESTORE=Path(folder),control=control)
            value=library.RecoveryObservation(module,Path(folder)/'report.json',lambda:False)
            try:
                with value.acl_checks({}):module.control('acl-read',{'paths':[MARKER]})
            except RuntimeError as error:self.assertIs(error,failure)
            else:self.fail('The original native failure was swallowed')
            self.assertIs(module.control,control);self.assertEqual(len(calls),1)
            module.control=lambda *args,**kwargs:{MARKER:'different'};original=module.control
            value.note_acl_mismatch=lambda *args:(_ for _ in ()).throw(RuntimeError(MARKER))
            with self.assertRaisesRegex(AssertionError,'original strict assertion'):
                with value.acl_checks({MARKER:{'exists':True,'sddl':'original'}}):
                    assert module.control('acl-read',{'paths':[MARKER]})[MARKER]=='original','original strict assertion'
            self.assertIs(module.control,original)

    def test_projection_types_bounds_categories_and_raw_value_privacy(self):
        library=observer();value=metadata();value['private']=MARKER;value['mismatches'][0]['dacl']['ace_bytes']=MARKER
        self.assertNotIn(MARKER,json.dumps(library.projected_acl(value)))
        for path,bad in [('schema',True),('report_status',[MARKER]),('mismatches',[metadata()['mismatches'][0]]*4)]:
            altered=copy.deepcopy(value);altered[path]=bad
            with self.assertRaises((ValueError,TypeError)):library.projected_acl(altered)
        for key,bad in [('file_category',MARKER),('owner_equal',1),('control_flags_before',True),('control_flags_xor',65536),('descriptor_revision_before',256)]:
            altered=copy.deepcopy(value);altered['mismatches'][0][key]=bad
            with self.assertRaises(ValueError):library.projected_acl(altered)
        for key,bad in [('raw_binary_equal',MARKER),('revision_before',True),('count_after',65536),('size_before',-1)]:
            altered=copy.deepcopy(value);altered['mismatches'][0]['dacl'][key]=bad
            with self.assertRaises(ValueError):library.projected_acl(altered)

    def test_actual_powershell_final_projection_and_no_file_access_in_metadata_helper(self):
        powershell=os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('pwsh');self.assertTrue(powershell)
        with tempfile.TemporaryDirectory() as folder:
            directory=Path(folder);report=directory/'backup-qualification/report.json';report.parent.mkdir()
            record={'state':'failed','failure':{'schema':1,'recovery_observation':{'schema':1,'acl_observation':metadata()|{'control_restored':True}}}}
            record['failure']['recovery_observation']['acl_observation']['mismatches'][0]['private']=MARKER
            report.write_text(json.dumps(record));script=directory/'controls.ps1';script.write_text(PROJECTION_CONTROLS)
            native=directory/'native-controls.ps1';native.write_text(NATIVE_CONTROLS)
            result=subprocess.run([powershell,'-NoProfile','-File',str(script),str(ROOT/'tests/windows-suite.ps1'),str(ROOT/'tests/windows-backup-sddl.ps1'),str(report),str(native)],capture_output=True,timeout=30)
            self.assertEqual(result.returncode,0,'Actual source projection controls failed');self.assertNotIn(MARKER,result.stdout.decode());self.assertNotIn(MARKER,result.stderr.decode())
            self.assertEqual(json.loads(result.stdout)['state'],'passed')

    def test_actual_acl_metadata_algorithm_with_explicit_synthetic_binary_objects(self):
        powershell=os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('pwsh');self.assertTrue(powershell)
        with tempfile.TemporaryDirectory() as folder:
            script=Path(folder)/'algorithm.ps1';script.write_text(ALGORITHM_CONTROLS)
            result=subprocess.run([powershell,'-NoProfile','-File',str(script),str(ROOT/'tests/windows-backup-sddl.ps1')],capture_output=True,timeout=30)
            self.assertEqual(result.returncode,0,'Actual ACL metadata algorithm controls failed')
            self.assertEqual(json.loads(result.stdout)['mode'],'synthetic_binary_objects')


PROJECTION_CONTROLS=r'''
param([string]$Suite,[string]$Helper,[string]$Report,[string]$NativeControls)
$ErrorActionPreference='Stop';$count=0
function Check([bool]$Value){if(!$Value){throw 'A security metadata projection control failed.'};$script:count++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Suite,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
$function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'BackupFailureReport'},$true)
. ([scriptblock]::Create($function.Extent.Text))
$safe=BackupFailureReport $Report ([datetime]::MinValue);$item=$safe.recovery_observation.acl_observation.mismatches[0]
Check ($item.file_category -ceq 'config' -and $item.control_flags_xor -eq 4096 -and $item.owner_equal -is [bool])
Check ($item.dacl.revision_before -eq 2 -and $item.dacl.raw_binary_equal -is [bool] -and $safe.recovery_observation.acl_observation.control_restored)
Check (!(($safe|ConvertTo-Json -Depth 12 -Compress).Contains('private-path-SID-descriptor-marker')))
$record=Get-Content -LiteralPath $Report -Raw|ConvertFrom-Json
foreach($key in 'file_category','owner_equal','control_flags_before'){
 $original=$record.failure.recovery_observation.acl_observation.mismatches[0].$key
 $record.failure.recovery_observation.acl_observation.mismatches[0].$key=@($original,'private-path-SID-descriptor-marker')
 [IO.File]::WriteAllText($Report,($record|ConvertTo-Json -Depth 12))
 Check ((BackupFailureReport $Report ([datetime]::MinValue)).recovery_observation.acl_observation.mismatches.Count -eq 0)
 $record.failure.recovery_observation.acl_observation.mismatches[0].$key=$original
}
$record.failure.recovery_observation.acl_observation.mismatches[0].dacl.count_before=$true
[IO.File]::WriteAllText($Report,($record|ConvertTo-Json -Depth 12));Check ((BackupFailureReport $Report ([datetime]::MinValue)).recovery_observation.acl_observation.mismatches.Count -eq 0)
$ast=[Management.Automation.Language.Parser]::ParseFile($Helper,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
$commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()})
foreach($forbidden in 'Get-Acl','Set-Acl','Get-Item','Get-Content','Set-Content','Start-Process','Get-Service','Set-Service'){Check ($forbidden -cnotin $commands)}
$null=[Management.Automation.Language.Parser]::ParseFile($NativeControls,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
[Console]::Out.WriteLine((@{state='passed';checks=$count}|ConvertTo-Json -Compress))
'''


ALGORITHM_CONTROLS=r'''
param([string]$Helper)
$ErrorActionPreference='Stop';$count=0
function Check([bool]$Value){if(!$Value){throw 'An ACL metadata algorithm control failed.'};$script:count++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Helper,[ref]$tokens,[ref]$errors)
foreach($name in 'EqualBytes','BinaryForm','AclMetadata'){
 $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
 . ([scriptblock]::Create($function.Extent.Text))
}
Add-Type @'
using System;using System.Collections;using System.Collections.Generic;
public sealed class PrivateAce{public readonly byte[] Bytes;public PrivateAce(byte value){Bytes=new byte[]{value,7,8,9};}public int BinaryLength{get{return Bytes.Length;}}public void GetBinaryForm(byte[] output,int offset){Array.Copy(Bytes,0,output,offset,Bytes.Length);}}
public sealed class PrivateAcl:IEnumerable{public readonly List<PrivateAce> Aces=new List<PrivateAce>();public byte Revision{get;set;}public int Count{get{return Aces.Count;}}public int BinaryLength{get{return 8+Count*4;}}public void GetBinaryForm(byte[] output,int offset){output[offset]=Revision;output[offset+1]=(byte)Count;for(int i=0;i<Count;i++)Aces[i].GetBinaryForm(output,offset+8+i*4);}public IEnumerator GetEnumerator(){return Aces.GetEnumerator();}}
'@
function Fixture([int]$Revision,[int[]]$Values){$acl=New-Object PrivateAcl;$acl.Revision=[byte]$Revision;foreach($value in $Values){$acl.Aces.Add((New-Object PrivateAce ([byte]$value)))};return ,$acl}
$one=Fixture 2 @(1,2);$two=Fixture 2 @(2,1);$before=BinaryForm $one;$after=BinaryForm $two
$value=AclMetadata $one $two
Check (!$value.raw_binary_equal -and !$value.ace_sequence_equal -and $value.ace_set_equal -and $value.ace_multiset_equal -and $value.ace_multiplicity_equal)
Check ($value.count_before -eq 2 -and $value.unique_ace_count_before -eq 2 -and $value.duplicate_ace_count_before -eq 0)
Check ((EqualBytes $before (BinaryForm $one)) -and (EqualBytes $after (BinaryForm $two)))
$value=AclMetadata (Fixture 2 @(1,1,2)) (Fixture 2 @(1,2,2))
Check ($value.count_before -eq $value.count_after -and $value.size_before -eq $value.size_after -and $value.ace_set_equal -and !$value.ace_multiset_equal -and !$value.ace_multiplicity_equal -and $value.duplicate_ace_count_before -eq 1)
$value=AclMetadata (Fixture 2 @(1)) (Fixture 4 @(1))
Check (!$value.raw_binary_equal -and $value.ace_sequence_equal -and $value.revision_before -eq 2 -and $value.revision_after -eq 4)
$value=AclMetadata $null (Fixture 2 @())
Check ($value.before_null -and !$value.after_null -and !$value.raw_binary_equal -and !$value.ace_set_equal -and !$value.all_ordinary_allow_before -and !$value.all_ordinary_allow_after)
$value=AclMetadata $null $null;Check ($value.raw_binary_equal -and $value.ace_multiset_equal -and $null -eq $value.revision_before)
$value=AclMetadata (Fixture 2 @(1)) (Fixture 2 @(1));Check ($value.raw_binary_equal -and $value.ace_sequence_equal -and $value.ace_multiset_equal -and !$value.all_ordinary_allow_before)
[Console]::Out.WriteLine((@{state='passed';mode='synthetic_binary_objects';checks=$count}|ConvertTo-Json -Compress))
'''


@unittest.skipUnless(os.name=='nt','Native RawSecurityDescriptor controls require Windows; no native result is implied locally.')
class NativeMetadata(unittest.TestCase):
    def test_actual_raw_descriptors_acl_order_multiplicity_and_control_bits(self):
        powershell=str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe')
        with tempfile.TemporaryDirectory() as folder:
            script=Path(folder)/'native.ps1';script.write_text(NATIVE_CONTROLS)
            result=subprocess.run([powershell,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(script),str(ROOT/'tests/windows-backup-sddl.ps1')],capture_output=True,timeout=30)
            self.assertEqual(result.returncode,0,'Native descriptor metadata controls failed')
            self.assertEqual(json.loads(result.stdout)['state'],'passed')


NATIVE_CONTROLS=r'''
param([string]$Helper)
$ErrorActionPreference='Stop';$count=0
function Check([bool]$Value){if(!$Value){throw 'A native descriptor metadata control failed.'};$script:count++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Helper,[ref]$tokens,[ref]$errors)
foreach($name in 'EqualBytes','BinaryForm','AclMetadata','DescriptorObjects','DescriptorMetadata'){
 $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
 . ([scriptblock]::Create($function.Extent.Text))
}
function Descriptor([string]$Sddl){return New-Object Security.AccessControl.RawSecurityDescriptor $Sddl}
function Acl([int]$Revision,$Aces){$value=New-Object Security.AccessControl.RawAcl ([byte]$Revision),16;foreach($ace in $Aces){$value.InsertAce($value.Count,$ace)};return ,$value}
$one=Descriptor 'O:SYG:BAD:(A;;FA;;;SY)(A;;FR;;;BA)';$two=Descriptor 'O:BAG:SYD:(A;;FA;;;SY)(A;;FR;;;BA)'
$before=BinaryForm $one;$after=BinaryForm $two;$value=DescriptorObjects $one $two
Check (!$value.owner_equal -and !$value.group_equal -and $value.dacl.raw_binary_equal -and !$value.descriptor_binary_equal)
Check ((EqualBytes $before (BinaryForm $one)) -and (EqualBytes $after (BinaryForm $two)))
$two=Descriptor 'O:SYG:BAD:(A;;FA;;;SY)(A;;FR;;;BA)'
foreach($flag in [Enum]::GetValues([Security.AccessControl.ControlFlags])){
 $two.SetFlags([Security.AccessControl.ControlFlags]([int]$one.ControlFlags -bxor [int]$flag));$value=DescriptorObjects $one $two
 Check ($value.control_flags_before -eq [int]$one.ControlFlags -and $value.control_flags_after -eq [int]$two.ControlFlags -and $value.control_flags_xor -eq ([int]$one.ControlFlags -bxor [int]$two.ControlFlags))
}
$a=$one.DiscretionaryAcl[0];$b=$one.DiscretionaryAcl[1]
$value=AclMetadata (Acl 2 @($a,$b)) (Acl 2 @($b,$a))
Check (!$value.raw_binary_equal -and !$value.ace_sequence_equal -and $value.ace_set_equal -and $value.ace_multiset_equal -and $value.ace_multiplicity_equal)
$value=AclMetadata (Acl 2 @($a,$a,$b)) (Acl 2 @($a,$b,$b))
Check ($value.count_before -eq $value.count_after -and $value.size_before -eq $value.size_after -and $value.ace_set_equal -and !$value.ace_multiset_equal -and !$value.ace_multiplicity_equal -and $value.duplicate_ace_count_before -eq 1)
$value=AclMetadata (Acl 2 @($a)) (Acl 4 @($a))
Check (!$value.raw_binary_equal -and $value.ace_multiset_equal -and $value.revision_before -eq 2 -and $value.revision_after -eq 4)
$value=AclMetadata $null (Acl 2 @())
Check ($value.before_null -and !$value.after_null -and !$value.raw_binary_equal -and !$value.ace_multiset_equal -and !$value.all_ordinary_allow_before -and !$value.all_ordinary_allow_after)
$deny=(Descriptor 'D:(D;;FR;;;SY)').DiscretionaryAcl
$value=AclMetadata (Acl 2 @($a)) $deny;Check ($value.all_ordinary_allow_before -and !$value.all_ordinary_allow_after)
$callback=New-Object Security.AccessControl.CommonAce ([Security.AccessControl.AceFlags]::None),([Security.AccessControl.AceQualifier]::AccessAllowed),1,$a.SecurityIdentifier,$true,([byte[]]@(1,2,3,4))
$value=AclMetadata (Acl 2 @($a)) (Acl 2 @($callback));Check (!$value.all_ordinary_allow_after -and !$value.ace_multiset_equal)
$object=New-Object Security.AccessControl.ObjectAce ([Security.AccessControl.AceFlags]::None),([Security.AccessControl.AceQualifier]::AccessAllowed),1,$a.SecurityIdentifier,([Security.AccessControl.ObjectAceFlags]::None),([Guid]::Empty),([Guid]::Empty),$false,$null
$value=AclMetadata (Acl 2 @($a)) (Acl 4 @($object));Check (!$value.all_ordinary_allow_after -and !$value.ace_multiset_equal)
$value=DescriptorMetadata @{file_category='config';before='O:SYG:BAD:(A;;FA;;;SY)';after='O:SYG:BAD:P(A;;FA;;;SY)'}
Check (!$value.strict_sddl_equal -and $value.owner_equal -and $value.group_equal -and $value.dacl.raw_binary_equal -and $value.control_flags_xor -eq 4096)
[Console]::Out.WriteLine((@{state='passed';checks=$count}|ConvertTo-Json -Compress))
'''


if __name__=='__main__':unittest.main()
