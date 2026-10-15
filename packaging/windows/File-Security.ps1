# Shared by owned file recovery only. Task Scheduler descriptors use their own contract.
# Named restoration reordered ACEs and SetFileSecurity lost AutoInherited in native controls.
# Restore only BACKUP_SECURITY_DATA, without any file-content stream or truncation:
# https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-backupwrite
function Initialize-OpenWebRawFileSecurity {
 if('OpenWebPbx.RawFileSecurityV1' -as [type]){return}
 Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace OpenWebPbx {
 public static class RawFileSecurityV1 {
  [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] struct TokenPrivileges { public uint Count; public Luid Luid; public uint Attributes; }
  sealed class TokenHandle : SafeHandleZeroOrMinusOneIsInvalid {
   public TokenHandle() : base(true) { }
   protected override bool ReleaseHandle() { return CloseHandle(handle); }
  }
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr LocalFree(IntPtr memory);
  [DllImport("advapi32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool OpenProcessToken(IntPtr process, uint access, out TokenHandle token);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool LookupPrivilegeValueW(string system, string name, out Luid luid);
  [DllImport("advapi32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool AdjustTokenPrivileges(TokenHandle token, [MarshalAs(UnmanagedType.Bool)] bool disableAll, ref TokenPrivileges state, uint length, out TokenPrivileges previous, out uint returned);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string value, uint revision, out IntPtr descriptor, out uint length);
  [DllImport("advapi32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetSecurityDescriptorOwner(IntPtr descriptor, out IntPtr owner, [MarshalAs(UnmanagedType.Bool)] out bool defaulted);
  [DllImport("advapi32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetSecurityDescriptorGroup(IntPtr descriptor, out IntPtr group, [MarshalAs(UnmanagedType.Bool)] out bool defaulted);
  [DllImport("advapi32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetSecurityDescriptorDacl(IntPtr descriptor, [MarshalAs(UnmanagedType.Bool)] out bool present, out IntPtr acl, [MarshalAs(UnmanagedType.Bool)] out bool defaulted);
  [DllImport("advapi32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetSecurityDescriptorSacl(IntPtr descriptor, [MarshalAs(UnmanagedType.Bool)] out bool present, out IntPtr acl, [MarshalAs(UnmanagedType.Bool)] out bool defaulted);
  [DllImport("advapi32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetSecurityDescriptorControl(IntPtr descriptor, out ushort control, out uint revision);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint sharing,IntPtr security,uint disposition,uint flags,IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool BackupWrite(SafeFileHandle file,IntPtr buffer,uint count,out uint written,[MarshalAs(UnmanagedType.Bool)] bool abort,[MarshalAs(UnmanagedType.Bool)] bool processSecurity,ref IntPtr context);

  static Win32Exception Failure(int code) { return new Win32Exception(code,"An original file security descriptor could not be restored."); }
  static void Check(bool success) { if(!success) throw Failure(Marshal.GetLastWin32Error()); }
  static void RecordCleanup(Exception primary,Exception cleanup,string key) {
   for(int depth=0;depth<4 && cleanup.InnerException!=null;depth++)cleanup=cleanup.InnerException;
   Win32Exception native=cleanup as Win32Exception;
   primary.Data[key+"_type"]=native!=null?"Win32Exception":"unknown";
   primary.Data[key+"_code"]=native!=null?native.NativeErrorCode:cleanup.HResult;
  }
  public static void RecordPrivilegeCleanup(Exception primary,Exception cleanup) { RecordCleanup(primary,cleanup,"file_security_privilege_cleanup"); }
  public static uint FileAccessMask(bool hasSacl) {
   // Without ACCESS_SYSTEM_SECURITY, BackupWrite leaves the existing SACL untouched.
   return 0x00080000u|0x00040000u|(hasSacl?0x01000000u:0u);
  }
  public static byte[] SecurityStream(byte[] descriptor) {
   if(descriptor==null || descriptor.Length==0 || descriptor.Length>262144)throw new ArgumentException("A file security descriptor is invalid.");
   byte[] stream=new byte[20+descriptor.Length];
   Array.Copy(BitConverter.GetBytes(3u),0,stream,0,4); // BACKUP_SECURITY_DATA only.
   Array.Copy(BitConverter.GetBytes(2u),0,stream,4,4); // STREAM_CONTAINS_SECURITY.
   Array.Copy(BitConverter.GetBytes((long)descriptor.Length),0,stream,8,8);
   Array.Copy(descriptor,0,stream,20,descriptor.Length); // Stream-name length remains zero.
   return stream;
  }
  static void WriteSecurity(string path,IntPtr descriptor,uint length,bool hasSacl) {
   byte[] bytes=new byte[length];Marshal.Copy(descriptor,bytes,0,(int)length);
   byte[] stream=SecurityStream(bytes);IntPtr context=IntPtr.Zero;Exception primary=null;GCHandle pinned=new GCHandle();bool attempted=false;
   // OPEN_EXISTING, synchronous BACKUP_SEMANTICS + OPEN_REPARSE_POINT; no data-write access.
   using(SafeFileHandle file=CreateFileW(path,FileAccessMask(hasSacl),7,IntPtr.Zero,3,0x02200000u,IntPtr.Zero)) {
    if(file.IsInvalid)throw Failure(Marshal.GetLastWin32Error());
    try {
     pinned=GCHandle.Alloc(stream,GCHandleType.Pinned);int offset=0;
     while(offset<stream.Length) {
      uint written;attempted=true;
      Check(BackupWrite(file,IntPtr.Add(pinned.AddrOfPinnedObject(),offset),(uint)(stream.Length-offset),out written,false,true,ref context));
      if(written==0 || written>stream.Length-offset)throw Failure(13);
      offset+=(int)written;
     }
    } catch(Exception error) { primary=error; }
    finally {
     if(attempted) {
      try { uint ignored;Check(BackupWrite(file,IntPtr.Zero,0,out ignored,true,true,ref context)); }
      catch(Exception cleanup) { if(primary==null)primary=cleanup;else RecordCleanup(primary,cleanup,"file_security_backup_cleanup"); }
     }
     if(pinned.IsAllocated)pinned.Free();
    }
   }
   if(primary!=null)ExceptionDispatchInfo.Capture(primary).Throw();
  }
  public sealed class PrivilegeLease : IDisposable {
   readonly TokenHandle token;
   readonly List<TokenPrivileges> previous=new List<TokenPrivileges>();
   bool disposed;
   public bool HasSacl { get; private set; }
   internal PrivilegeLease(bool hasSacl) {
    HasSacl=hasSacl;
    Check(OpenProcessToken(GetCurrentProcess(),0x0020u|0x0008u,out token));
    try { Enable("SeRestorePrivilege"); if(hasSacl) Enable("SeSecurityPrivilege"); }
    catch(Exception error) {
     try { Dispose(); } catch(Exception cleanup) { RecordPrivilegeCleanup(error,cleanup); }
     throw;
    }
   }
   void Enable(string name) {
    Luid luid;Check(LookupPrivilegeValueW(null,name,out luid));
    TokenPrivileges state=new TokenPrivileges { Count=1,Luid=luid,Attributes=2 };
    TokenPrivileges old;uint returned;
    bool success=AdjustTokenPrivileges(token,false,ref state,(uint)Marshal.SizeOf(typeof(TokenPrivileges)),out old,out returned);
    int error=Marshal.GetLastWin32Error();
    if(success && old.Count!=0) previous.Add(old);
    if(!success || error!=0) throw Failure(error);
   }
   public void Dispose() {
    if(disposed)return;disposed=true;int failure=0;
    try {
     for(int index=previous.Count-1;index>=0;index--) {
      TokenPrivileges state=previous[index],ignored;uint returned;
      bool success=AdjustTokenPrivileges(token,false,ref state,(uint)Marshal.SizeOf(typeof(TokenPrivileges)),out ignored,out returned);
      int error=Marshal.GetLastWin32Error();if((!success || error!=0) && failure==0)failure=error!=0?error:31;
     }
    } finally { token.Dispose(); }
    if(failure!=0)throw Failure(failure);
   }
  }
  public static PrivilegeLease Apply(string path,string sddl) {
   if(String.IsNullOrWhiteSpace(path) || path.Length>32767 || path.IndexOf('\0')>=0 || String.IsNullOrWhiteSpace(sddl) || sddl.Length>131072 || sddl.IndexOf('\0')>=0)
    throw new ArgumentException("A file security restoration request is invalid.");
   IntPtr descriptor=IntPtr.Zero;PrivilegeLease lease=null;Exception primary=null;
   try {
    uint length;Check(ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl,1,out descriptor,out length));
    if(descriptor==IntPtr.Zero || length==0 || length>262144)throw new ArgumentException("A file security descriptor is invalid.");
    IntPtr owner,group,dacl,sacl;bool defaulted,daclPresent,saclPresent;ushort control;uint revision;
    Check(GetSecurityDescriptorOwner(descriptor,out owner,out defaulted));
    Check(GetSecurityDescriptorGroup(descriptor,out group,out defaulted));
    Check(GetSecurityDescriptorDacl(descriptor,out daclPresent,out dacl,out defaulted));
    Check(GetSecurityDescriptorSacl(descriptor,out saclPresent,out sacl,out defaulted));
    Check(GetSecurityDescriptorControl(descriptor,out control,out revision));
    if(owner==IntPtr.Zero || group==IntPtr.Zero || !daclPresent || revision!=1)throw new ArgumentException("A complete original file security descriptor is required.");
    lease=new PrivilegeLease(saclPresent);
    WriteSecurity(path,descriptor,length,saclPresent);
   } catch(Exception error) { primary=error; }
   finally {
    if(descriptor!=IntPtr.Zero && LocalFree(descriptor)!=IntPtr.Zero) {
     Exception cleanup=Failure(Marshal.GetLastWin32Error());
     if(primary==null)primary=cleanup;else RecordCleanup(primary,cleanup,"file_security_buffer_cleanup");
    }
    if(primary!=null && lease!=null) {
     try { lease.Dispose(); } catch(Exception cleanup) { RecordPrivilegeCleanup(primary,cleanup); }
     lease=null;
    }
   }
   if(primary!=null)ExceptionDispatchInfo.Capture(primary).Throw();
   return lease;
  }
 }
}
'@
}
function Set-OpenWebFileSddl {
 param([Parameter(Mandatory)][string]$LiteralPath,[Parameter(Mandatory)][string]$Sddl)
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Raw file security restoration requires Windows.'}
 $path=[IO.Path]::GetFullPath($LiteralPath)
 if($path -notmatch '^[A-Za-z]:\\' -or $path.Length -gt 32767 -or [string]::IsNullOrWhiteSpace($Sddl) -or $Sddl.Length -gt 131072 -or $Sddl.IndexOf([char]0) -ge 0){throw 'A file security restoration request is invalid.'}
 $current=$path
 while($current){
  $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'File security restoration paths must not contain links or junctions.'}
  $parent=[IO.Path]::GetDirectoryName($current);if($parent -eq $current){break};$current=$parent
 }
 Initialize-OpenWebRawFileSecurity
 $lease=$null;$primary=$null
 try{
  $lease=[OpenWebPbx.RawFileSecurityV1]::Apply($path,$Sddl)
  $actual=if($lease.HasSacl){(Get-Acl -LiteralPath $path -Audit -ErrorAction Stop).Sddl}else{(Get-Acl -LiteralPath $path -ErrorAction Stop).Sddl}
  if(![string]::Equals($actual,$Sddl,[StringComparison]::Ordinal)){throw 'The original file security descriptor did not restore exactly.'}
 }catch{$primary=$_.Exception;throw}
 finally{
  if($lease){try{$lease.Dispose()}catch{if($primary){[OpenWebPbx.RawFileSecurityV1]::RecordPrivilegeCleanup($primary,$_.Exception)}else{throw}}}
 }
}
