local binding=dofile('app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/auth_binding.lua')
local count=0
local function copy(v) local r={} for k,x in pairs(v) do r[k]=x end return r end
local function check(v,why) if not v then error(why) end count=count+1 end
local row={auth_user='auth-A',extension_uuid='uuid-a',domain_uuid='domain-a',domain_name='a.example.test',user_enabled='true',domain_enabled='true',suspended='false',restore_realm='a.example.test',restore_number='100',restore_enabled='true',restore_auth='auth-A',restore_uuid='uuid-a',canonical_collision='false'}
local request={user='auth-A',domain='a.example.test',method='REGISTER',from_user='100',to_user='100',from_domain='a.example.test',to_domain='a.example.test'}
check(binding.allowed({copy(row)},request)~=nil,'Original extension AOR and distinct digest identity bind.')
local nulls=copy(row);nulls.contact_user='';check(binding.allowed({nulls},request)~=nil,'Database NULL converted to empty contact still uses source number.')
for _,method in ipairs({'INVITE','SUBSCRIBE','NOTIFY','MESSAGE','OPTIONS','REFER','UPDATE','INFO','BYE','PRACK'}) do local q=copy(request);q.method=method;q.to_user='other-destination';check(binding.allowed({copy(row)},q)~=nil,'Authenticated method preserves original From: '..method) end
for _,field in ipairs({'from_user','to_user','user','domain','from_domain','to_domain'}) do local q=copy(request);q[field]='foreign';check(binding.allowed({copy(row)},q)==nil,'Foreign identity/realm rejected: '..field) end
for _,field in ipairs({'user_enabled','domain_enabled','restore_enabled'}) do local r=copy(row);r[field]='false';check(binding.allowed({r},request)==nil,'Disabled binding rejected: '..field) end
for _,field in ipairs({'restore_realm','restore_auth','restore_uuid'}) do local r=copy(row);r[field]='foreign';check(binding.allowed({r},request)==nil,'Restored ownership mismatch rejected: '..field) end
local r=copy(row);r.suspended='true';check(binding.allowed({r},request)==nil,'Suspended tenant rejected before cache.')
check(binding.allowed({copy(row),copy(row)},request)==nil,'Duplicate identity fails closed.')
check(binding.allowed({},request)==nil,'Missing identity fails closed.')
local q=copy(request);q.from_user=nil;check(binding.allowed({copy(row)},q)==nil,'Missing authenticated From fails closed.')
q=copy(request);q.method='unknown';check(binding.allowed({copy(row)},q)==nil,'Unknown authenticated method fails closed.')
r=copy(row);r.auth_user='101';r.restore_auth='101';r.restore_number='100';r.canonical_collision='true';q=copy(request);q.user='101';check(binding.allowed({r},q)~=nil,'Numeric AuthID collision still binds exact source owner.')
q=copy(q);q.from_user='101';q.to_user='101';check(binding.allowed({r},q)==nil,'Numeric collision cannot claim the other extension AOR.')
q=copy(request);q.from_user='auth-A';q.to_user='auth-A';check(binding.allowed({copy(row)},q)~=nil,'Existing canonical AuthID AOR remains valid without source-number collision.')
r=copy(row);r.canonical_collision=nil;check(binding.allowed({r},q)==nil,'Missing collision evidence fails closed for alternate canonical AOR.')
q=copy(request);q.to_user='auth-A';check(binding.allowed({copy(row)},q)==nil,'REGISTER cannot mix the two permitted AOR pairs.')
local ordinary={auth_user='ordinary',extension_uuid='uuid-o',domain_name='a.example.test',user_enabled='true',domain_enabled='true',suspended='false',number_alias='200',alias_collision='false'}
q=copy(request);q.user='ordinary';q.from_user='ordinary';q.to_user='ordinary';check(binding.allowed({ordinary},q)~=nil,'Ordinary exact identity remains supported.')
nulls=copy(ordinary);nulls.restore_number='';check(binding.allowed({nulls},q)~=nil,'Database NULL converted to empty restore number retains ordinary identity.')
q.from_user='200';q.to_user='200';check(binding.allowed({ordinary},q)==nil,'Unconfigured alias does not bypass identity matching.')
q.alias_enabled=true;check(binding.allowed({ordinary},q)~=nil,'Explicit unambiguous ordinary alias remains supported.')
r=copy(ordinary);r.alias_collision='true';check(binding.allowed({r},q)==nil,'Configured alias collision rejected.')
q.from_user='ordinary';q.to_user='ordinary';check(binding.allowed({ordinary},q)~=nil,'Explicit alias setting retains ordinary canonical AOR.')
local alias_row=copy(row);alias_row.requested_domain='phones.example.test'
local alias_request=copy(request);alias_request.domain='phones.example.test';alias_request.from_domain='phones.example.test';alias_request.to_domain='phones.example.test'
check(binding.allowed({alias_row},alias_request)~=nil,'Owned alias authenticates its exact original AOR while retaining canonical restore realm.')
local foreign_alias=copy(alias_request);foreign_alias.from_domain=row.domain_name
check(binding.allowed({copy(alias_row)},foreign_alias)==nil,'Owned alias cannot mix a canonical From realm with the requested realm.')
foreign_alias=copy(alias_request);foreign_alias.to_domain=row.domain_name
check(binding.allowed({copy(alias_row)},foreign_alias)==nil,'Owned alias cannot mix a canonical To realm with the requested realm.')
alias_row.restore_realm='foreign.example.test'
check(binding.allowed({alias_row},alias_request)==nil,'Alias cannot bypass canonical restore ownership.')
print('PASS: '..count..' total binding checks including exact owned aliases.')
