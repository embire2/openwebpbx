// SPDX-License-Identifier: AGPL-3.0-or-later
using OpenWebPbx.Phone.MediaChecks;
using System.Buffers.Binary;
var root=Path.Combine(Path.GetTempPath(),"openweb-wav-readiness-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);var path=Path.Combine(root,"owned.wav");var checks=0;
void Check(bool value){if(!value)throw new InvalidOperationException("Readiness contract refused");checks++;}
void Refuse(){try{_ = PcmWave.Read(path,true);}catch(InvalidDataException){checks++;return;}throw new InvalidOperationException("Original strict parser admitted malformed/empty input");}
try{
 File.WriteAllBytes(path,[]);Check(!FirstDataReadiness.Ready(path));Refuse();
 // Invented empty-header test vector; never produced by or supplied to a call.
 byte[] empty=[82,73,70,70,36,0,0,0,87,65,86,69,102,109,116,32,16,0,0,0,1,0,1,0,64,31,0,0,128,62,0,0,2,0,16,0,100,97,116,97,0,0,0,0];File.WriteAllBytes(path,empty);Check(empty.Length==44&&!FirstDataReadiness.Ready(path));Refuse();
 File.WriteAllBytes(path,new byte[10]);Check(FirstDataReadiness.Ready(path));Refuse();
 File.WriteAllBytes(path,new byte[44]);Check(FirstDataReadiness.Ready(path));Refuse();
 File.WriteAllBytes(path,new byte[81920]);Check(FirstDataReadiness.Ready(path));Refuse();
 foreach(var offset in new[]{0,4,8,12,16,20,22,24,28,32,34,36,40}){var bad=empty.ToArray();bad[offset]^=0x7f;File.WriteAllBytes(path,bad);Check(FirstDataReadiness.Ready(path));Refuse();}
 File.Delete(path);PcmWave.Write(path,[425],1);Check(FirstDataReadiness.Ready(path));var parsed=PcmWave.Read(path,true);Check(parsed.Rate==8000&&parsed.Samples.Length==8000);
 // The helper performs no write/repair of a malformed final header.
 var malformed=File.ReadAllBytes(path);BinaryPrimitives.WriteUInt32LittleEndian(malformed.AsSpan(4),3);File.WriteAllBytes(path,malformed);Check(FirstDataReadiness.Ready(path));Check(File.ReadAllBytes(path).SequenceEqual(malformed));try{_ = PcmWave.Read(path,false);throw new InvalidOperationException();}catch(InvalidDataException){checks++;}
 Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new{schema=1,state="passed_private_first_data_and_original_parser_contract",checks,actual_native_calling=false,native_plugin_built=false,original_parser_changed=false}));
}finally{File.Delete(path);Directory.Delete(root);}
