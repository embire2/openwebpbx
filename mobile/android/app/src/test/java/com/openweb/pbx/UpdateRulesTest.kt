/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx
import org.junit.Assert.*
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.Signature
import java.util.Base64
class UpdateRulesTest {
    private fun rejects(work:()->Unit){try{work();fail("Must reject invalid release input")}catch(_:IllegalArgumentException){}}
    @Test fun detachedSignatureChecksExactBytesAndKey(){
        val generator=KeyPairGenerator.getInstance("RSA");generator.initialize(2048);val pair=generator.generateKeyPair()
        val bytes="signed release payload".toByteArray();val encoded=Base64.getEncoder().encodeToString(bytes)
        val signature=Base64.getEncoder().encodeToString(Signature.getInstance("SHA256withRSA").run{initSign(pair.private);update(bytes);sign()})
        val pem="-----BEGIN PUBLIC KEY-----\n"+Base64.getEncoder().encodeToString(pair.public.encoded)+"\n-----END PUBLIC KEY-----"
        assertArrayEquals(bytes,UpdateRules.verify(encoded,signature,pem))
        rejects{UpdateRules.verify(Base64.getEncoder().encodeToString("modified".toByteArray()),signature,pem)}
        val other="-----BEGIN PUBLIC KEY-----\n"+Base64.getEncoder().encodeToString(generator.generateKeyPair().public.encoded)+"\n-----END PUBLIC KEY-----"
        rejects{UpdateRules.verify(encoded,signature,other)}
        rejects{UpdateRules.verify("!",signature,pem)}
    }
    @Test fun onlyExactReleaseAssetAndAllowedHttpsRedirects(){
        val name="openwebpbx-1.0.5-android.apk";val url="https://github.com/embire2/openwebpbx/releases/download/v1.0.5/$name"
        assertTrue(UpdateRules.trustedUrl(url,"1.0.5",name))
        for(bad in listOf(url.replace("https:","http:"),url.replace("github.com","github.com.evil.example"),url+"?other=1",url+"#hidden",url.replace("github.com","name@github.com"),url.replace("embire2","other")))assertFalse(bad,UpdateRules.trustedUrl(bad,"1.0.5",name))
        assertTrue(UpdateRules.trustedUrl("https://release-assets.githubusercontent.com/asset?token=release"))
        assertFalse(UpdateRules.trustedUrl("https://example.com/asset"));assertFalse(UpdateRules.trustedUrl("https://github.com/other/project/releases/file"))
    }
    @Test fun monotonicReleaseSequenceCannotBeRebound(){
        UpdateRules.sequence(105,"a",104,"b");UpdateRules.sequence(105,"a",105,"a")
        rejects{UpdateRules.sequence(104,"a",105,"a")};rejects{UpdateRules.sequence(105,"changed",105,"a")}
    }
    @Test fun requiredUpdateGateNeedsEverySafetyCondition(){
        assertTrue(UpdateRules.gate(true,true,true,true,false,false))
        assertFalse(UpdateRules.gate(false,true,true,true,false,false));assertFalse(UpdateRules.gate(true,false,true,true,false,false));assertFalse(UpdateRules.gate(true,true,false,true,false,false));assertFalse(UpdateRules.gate(true,true,true,false,false,false));assertFalse(UpdateRules.gate(true,true,true,true,true,false));assertFalse(UpdateRules.gate(true,true,true,true,false,true))
    }
    @Test fun versionsAreNumericAndPrereleasesRejected(){
        assertTrue(UpdateRules.compare("1.0.10","1.0.9")>0);assertTrue(UpdateRules.compare("2.0.0","1.99.99")>0)
        for(bad in listOf("1.0.5-preview","1.0","1.0.-1","1000000.0.0"))rejects{UpdateRules.version(bad)}
    }
    @Test fun friendlyCallFailuresDoNotExposeProtocolDetails(){
        assertTrue(CallFeedback.failure(503).contains("provider and calling rules"));assertTrue(CallFeedback.failure(486).contains("busy"));assertTrue(CallFeedback.failure(403).contains("permissions"))
        for(code in listOf(403,404,408,486,488,503,603,0))assertFalse(CallFeedback.failure(code).contains("SIP"))
    }
}
