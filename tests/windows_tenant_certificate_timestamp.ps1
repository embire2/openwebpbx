# Read-only certificate-expiry producer/consumer contract; never invoke ACME,
# IIS, certificate installation or the tenant worker.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$CertificateThumbprint='')
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:checks++}
$producer=Join-Path $SourceRoot 'packaging/windows/Tenant-Domains.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($producer,[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0) 'Actual tenant-domain producer must parse.'
$functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-OpenWebTenantOperation'},$true))
Check ($functions.Count -eq 1) 'One actual tenant operation is required.'
$returns=@($functions[0].FindAll({param($n)$n -is [Management.Automation.Language.ReturnStatementAst] -and $n.Extent.Text.StartsWith('return @{not_after=')},$true))
Check ($returns.Count -eq 1 -and $functions[0].Body.EndBlock.Statements[-1] -eq $returns[0]) 'The actual final certificate result is required.'
$emit=[scriptblock]::Create('param($certificate)'+[Environment]::NewLine+$returns[0].Extent.Text)
# Read the consumer's actual regex, not a more permissive test-owned format.
$gate=[IO.File]::ReadAllText((Join-Path $SourceRoot 'platform/OpenWebPbx.Server/OnboardingGate.cs'))
$method=[regex]::Match($gate,'(?s)private static bool Timestamp\(string value, out DateTimeOffset result\)\s*\{(?<body>.*?)\n    \}')
Check $method.Success 'The actual core timestamp parser is required.'
$pattern=[regex]::Match($method.Groups['body'].Value,'Regex\.IsMatch\(value, "(?<pattern>[^"\r\n]+)", RegexOptions\.CultureInvariant\)')
Check $pattern.Success 'The exact culture-invariant consumer regex is required.'
$consumerPattern=$pattern.Groups['pattern'].Value.Replace('\\','\')
Check ($consumerPattern.Contains('{1,6}') -and $method.Groups['body'].Value.Contains('DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out result)')) 'Core timestamp precision and parsing guards must remain strict.'
function ConsumerAccepts([string]$Value){
 $parsed=[DateTimeOffset]::MinValue
 return [regex]::IsMatch($Value,$consumerPattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant) -and [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)
}
$certificate=$null;$rsa=$null;$culture=[Threading.Thread]::CurrentThread.CurrentCulture
try{
 if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
  Check ($CertificateThumbprint -cmatch '^[A-F0-9]{40}$') 'An explicit owned Windows certificate is required.'
  $certificate=Get-Item -LiteralPath ('Cert:\LocalMachine\My\'+$CertificateThumbprint)
  Check ($certificate -is [Security.Cryptography.X509Certificates.X509Certificate2] -and $certificate.Thumbprint -ceq $CertificateThumbprint) 'Read the exact existing certificate only.'
 }else{
  Check (!$CertificateThumbprint) 'A Windows certificate-store selector is not portable.'
  $rsa=[Security.Cryptography.RSA]::Create(2048)
  $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=expiry-fixture.invalid',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
  $certificate=$request.CreateSelfSigned([DateTimeOffset]'2031-01-01T00:00:00Z',[DateTimeOffset]'2032-06-07T08:09:10Z')
 }
 $expected=$certificate.NotAfter.ToUniversalTime()
 Check (($expected.Ticks % [TimeSpan]::TicksPerSecond) -eq 0) 'Actual X.509 expiry precision is whole seconds.'
 $old=$expected.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
 Check ($old -cmatch '\.\d{7}Z$' -and !(ConsumerAccepts $old)) 'Retain the original seven-digit producer refusal.'
 foreach($name in 'en-US','th-TH','ar-SA'){
  [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($name)
  $result=& $emit $certificate
  Check ($result -is [Collections.IDictionary] -and $result.Count -eq 1 -and $result.ContainsKey('not_after')) 'The exact single-field machine result must remain unchanged.'
  $value=$result.not_after
  Check ($value -is [string] -and $value -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') 'Producer emits invariant whole-second UTC.'
  Check (ConsumerAccepts $value) 'The unchanged actual core timestamp predicate admits the real certificate expiry.'
  $parsed=[DateTimeOffset]::Parse($value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
  Check ($parsed.UtcDateTime.Ticks -eq $expected.Ticks) 'The producer must preserve the actual certificate expiry instant.'
 }
 foreach($bad in '2032-06-07T08:09:10.0000000Z','2032-06-07T08:09:10+02:00','not-a-time','2032-99-07T08:09:10Z'){
  Check (!(ConsumerAccepts $bad)) 'Seven digits, non-UTC, malformed and impossible dates stay refused.'
 }
 Write-Output ("PASS $checks actual producer/parser/real-certificate expiry controls; no IIS, ACME, worker or certificate-store changes.")
}finally{
 [Threading.Thread]::CurrentThread.CurrentCulture=$culture
 if($certificate){$certificate.Dispose()};if($rsa){$rsa.Dispose()}
}
