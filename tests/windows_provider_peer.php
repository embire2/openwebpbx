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
