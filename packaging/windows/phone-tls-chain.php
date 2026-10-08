<?php
/** Preserve a supplied server chain without offering alternate system roots. */
function openweb_phone_tls_chain(string $leaf, string $bundle): string {
    if (strlen($bundle)>262144 || !preg_match_all('/-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+\/=\s]+-----END CERTIFICATE-----/', $bundle, $matches)
        || count($matches[0])>12 || trim(str_replace($matches[0], '', $bundle))!=='') {
        throw new RuntimeException('Use the complete certificate PEM chain supplied by your certificate authority.');
    }
    $certificates=$matches[0];$parsed=[];
    foreach ($certificates as $certificate) {
        $details=openssl_x509_parse($certificate);
        if (!$details || $details['validFrom_time_t']>time() || $details['validTo_time_t']<=time()) throw new RuntimeException('The supplied certificate chain is invalid or expired.');
        $parsed[]=$details;
    }
    if (!hash_equals(openssl_x509_fingerprint($leaf, 'sha256'), openssl_x509_fingerprint($certificates[0], 'sha256'))) {
        throw new RuntimeException('The certificate chain belongs to a different server certificate.');
    }
    for ($i=0; $i<count($certificates)-1; $i++) {
        if ($parsed[$i]['issuer']!=$parsed[$i+1]['subject'] || openssl_x509_verify($certificates[$i], openssl_pkey_get_public($certificates[$i+1]))!==1) {
            throw new RuntimeException('The supplied certificate chain is incomplete or out of order.');
        }
    }
    $last=count($certificates)-1;
    if ($parsed[$last]['subject']==$parsed[$last]['issuer'] && openssl_x509_verify($certificates[$last], openssl_pkey_get_public($certificates[$last]))===1) {
        if ($last===0) throw new RuntimeException('Choose a certificate issued by a trusted certificate authority.');
        array_pop($certificates);
    }
    // Sofia loads only the leaf from agent.pem. Its CA file supplies exactly
    // this issuer path; adding unrelated roots can replace a cross-signed path.
    return implode("\n", $certificates)."\n";
}
