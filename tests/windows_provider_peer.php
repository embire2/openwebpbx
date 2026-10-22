<?php
// Disposable peers must use the exact installed external profile's local
// address. Windows cannot send from a NIC-bound SIP socket to 127.0.0.1.
function windows_native_provider_profile_ipv4(string $raw): string {
    if(strlen($raw)>65536||preg_match_all('/^\s*SIP-IP\s+([0-9.]+)\s*$/m',$raw,$matches)!==1
        ||!filter_var($matches[1][0],FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))throw new RuntimeException('The exact external-profile address is unavailable or ambiguous.');
    return $matches[1][0];
}
function windows_native_provider_peer_address(string $peer,string $profile,array $local): string {
    if(count($local)>16||$peer!==$profile||!filter_var($peer,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)
        ||$peer==='0.0.0.0'||$peer==='255.255.255.255'||(int)explode('.',$peer)[0]>=224
        ||!in_array($peer,[...$local,'127.0.0.1'],true))throw new RuntimeException('The fictional provider must use the exact local external-profile address.');
    return $peer;
}
function windows_native_provider_ingress_address(string $stage,string $peer): string {
    if(!in_array($stage,['outbound','incoming'],true)||!filter_var($peer,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))throw new RuntimeException('A fixed fictional provider ingress stage is required.');
    // The peer and phone share the runner's NIC. Trusting that source during
    // ordinary phone calls would deliberately bypass the SIP digest challenge.
    // This documentation-only address is never a dial target or socket bind.
    if($peer==='198.51.100.254')throw new RuntimeException('The fictional ingress placeholder collides with the local peer.');
    return $stage==='incoming'?$peer:'198.51.100.254';
}
function windows_native_provider_acl(callable $api,string $address): bool {
    if(!filter_var($address,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))throw new RuntimeException('An exact local ACL observation address is required.');
    $raw=trim((string)$api('acl '.$address.' providers'));
    if(!in_array($raw,['true','false'],true))throw new RuntimeException('The actual provider ACL result is unavailable.');
    return $raw==='true';
}
function windows_native_provider_policy_identity(array $config,array $providers): string {
    if(count($providers)!==2||count($config['trunks']??[])!==2)throw new RuntimeException('Exactly the owned fictional providers are required.');
    if(count(array_unique(array_column($providers,'trunk')))!==2||count(array_unique(array_column($providers,'gateway')))!==2)throw new RuntimeException('The fictional provider bindings must be distinct.');
    foreach($providers as $provider){$key=$provider['trunk']??'';$trunk=$config['trunks'][$key]??null;
        if(!is_array($trunk)||($trunk['gateway_uuid']??null)!==($provider['gateway']??null)||($trunk['enabled']??null)!==true)throw new RuntimeException('The enabled fictional provider binding changed.');
        unset($config['trunks'][$key]['allowed_ips']);
    }
    return hash('sha256',json_encode($config,JSON_THROW_ON_ERROR));
}
