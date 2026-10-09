/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import java.net.URI
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/** Platform-independent trust checks. Signed metadata never grants permission to downgrade. */
object UpdateRules {
    const val FEED = "https://github.com/embire2/openwebpbx/releases/latest/download/update-manifest.json"
    const val KEY_ID = "release-2026-a"
    const val PACKAGE = "com.openweb.pbx"
    const val CERTIFICATE = "449740f6858cb092a0f67d9d79d2505a8d6e7e4d4c1a52a8eaed9b895e48e69d"
    const val MAX_ENVELOPE = 262144
    const val MAX_APK = 536870912L
    fun sha256(bytes:ByteArray)=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString(""){"%02x".format(it)}
    fun version(value:String):List<Int> { require(value.matches(Regex("[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}")));return value.split('.').map{it.toInt()} }
    fun compare(a:String,b:String):Int { val left=version(a);val right=version(b);for(i in 0..2)if(left[i]!=right[i])return left[i].compareTo(right[i]);return 0 }
    fun verify(payload:String,signature:String,pem:String):ByteArray {
        require(payload.length<=MAX_ENVELOPE && signature.length<=2048)
        val bytes=Base64.getDecoder().decode(payload);require(bytes.isNotEmpty() && bytes.size<=MAX_ENVELOPE)
        val key=KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(Base64.getDecoder().decode(pem.replace("-----BEGIN PUBLIC KEY-----","").replace("-----END PUBLIC KEY-----","").replace(Regex("\\s"),""))))
        require(Signature.getInstance("SHA256withRSA").run{initVerify(key);update(bytes);verify(Base64.getDecoder().decode(signature))}) { "Release signature is invalid" }
        return bytes
    }
    fun trustedUrl(value:String,version:String?=null,name:String?=null):Boolean = try {
        val u=URI(value)
        val safe=u.scheme=="https" && u.userInfo==null && u.fragment==null && (u.port==-1 || u.port==443)
        safe && if(version!=null && name!=null) u.host=="github.com" && u.rawQuery==null && u.rawPath=="/embire2/openwebpbx/releases/download/v$version/$name"
        else when(u.host) {
            "github.com" -> u.rawPath.startsWith("/embire2/openwebpbx/releases/")
            "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com" -> true
            else -> false
        }
    }catch(_:Exception){false}
    fun sequence(sequence:Long,digest:String,highest:Long,oldDigest:String) { require(sequence>=highest && (sequence!=highest || oldDigest.isEmpty() || digest==oldDigest)) { "Release metadata is older than a trusted release" } }
    fun gate(required:Boolean,verified:Boolean,supported:Boolean,checkSucceeded:Boolean,activeCall:Boolean,urgent:Boolean):Boolean = required && verified && supported && checkSucceeded && !activeCall && !urgent
}
