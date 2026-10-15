# Durable replacement of owned private state while the caller holds its lock.
function Write-OpenWebPrivateState {
 param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
 $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.new'
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 12))
 try{
  $file=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
  try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
  if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
 }finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
}
