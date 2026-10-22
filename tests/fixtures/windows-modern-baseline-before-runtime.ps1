# Exact modern guard from source807285037 before PHP/recovery receipts were mandatory.
 if([version]$BaseVersion -ge [version]'1.0.20'){
  foreach($gate in 'web_readiness','tenant_domains','meeting_transport','meeting_browser','phone_health','stun','native_clock','native_providers','native_call_me_back'){Check ($baseFacts.gates.$gate -is [string] -and $baseFacts.gates.$gate -ceq 'passed') 'The current Windows web, tenant, meeting, phone health, STUN, clock, provider and callback gates must all be qualified.'}
  $dtlsProof=$baseFacts.dtls_qualification
  Check ($null -ne $dtlsProof -and ($dtlsProof -is [pscustomobject] -or $dtlsProof -is [Collections.IDictionary]) -and $dtlsProof -isnot [Array]) 'The complete current native DTLS qualification record is required.'
  Check ($dtlsProof.state -is [string] -and $dtlsProof.state -ceq 'passed') 'The current native DTLS qualification must pass.'
  foreach($field in 'actual_native_windows','transaction_service_adapter_double'){Check ($dtlsProof.$field -is [bool] -and $dtlsProof.$field -eq $true) 'The native DTLS scope and explicit service-adapter double must match.'}
  foreach($limit in @(@('transaction_checks',62),@('crypto_checks',12),@('installed_checks',12))){$value=$dtlsProof.($limit[0]);Check (($value -is [int] -or $value -is [long]) -and $value -ge $limit[1] -and $value -le 10000) 'Every current native DTLS proof count must be complete and bounded.'}
 }
