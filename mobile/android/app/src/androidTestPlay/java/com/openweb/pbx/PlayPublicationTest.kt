/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.security.KeyPairGenerator
import java.security.Signature
import java.time.Instant
import java.util.Base64

@RunWith(AndroidJUnit4::class)
class PlayPublicationTest {
    private val key=KeyPairGenerator.getInstance("RSA").apply{initialize(2048)}.generateKeyPair()
    private val now=System.currentTimeMillis()
    private val pem="-----BEGIN PUBLIC KEY-----\n"+Base64.getEncoder().encodeToString(key.public.encoded)+"\n-----END PUBLIC KEY-----"
    private fun time(value:Long)=Instant.ofEpochMilli(value).toString().substringBefore('.').removeSuffix("Z")+"Z"
    private fun payload():JSONObject {
        val asset=JSONObject().put("platform","android-universal").put("name","openwebpbx-1.0.8-android.apk").put("url","https://github.com/embire2/openwebpbx/releases/download/v1.0.8/openwebpbx-1.0.8-android.apk")
            .put("package_id",UpdateRules.PACKAGE).put("certificate_sha256",UpdateRules.CERTIFICATE).put("bytes",1).put("sha256","0".repeat(64)).put("version_code",108).put("minimum_server_version","1.0.6").put("min_sdk",28)
        return JSONObject().put("schema",1).put("product","openwebpbx").put("channel","stable").put("sequence",108).put("version","1.0.8").put("published_at",time(now-1000)).put("expires_at",time(now+86400000)).put("assets",JSONArray().put(asset))
    }
    private fun play()=JSONObject().put("status","published").put("track","production").put("rollout","complete").put("package_id",UpdateRules.PACKAGE).put("version","1.0.7").put("version_code",107).put("minimum_server_version","1.0.6").put("min_sdk",28).put("published_at",time(now-2000))
    private fun signed(payload:JSONObject):String {
        val bytes=payload.toString().toByteArray(Charsets.UTF_8)
        val sig=Signature.getInstance("SHA256withRSA").run{initSign(key.private);update(bytes);sign()}
        return JSONObject().put("key_id",UpdateRules.KEY_ID).put("payload",Base64.getEncoder().encodeToString(bytes)).put("signature",Base64.getEncoder().encodeToString(sig)).toString()
    }
    private fun rejects(block:()->Unit){try{block();fail("Unverified Play availability must be refused")}catch(_:IllegalArgumentException){}}
    @Test fun githubReleaseAloneNeverAnnouncesAPlayUpdate(){
        val feed=PlayReleaseManifest.parse(signed(payload()),pem,now)
        assertEquals("1.0.8",feed.verified.version);assertNull(feed.release)
        assertNull(PlayReleaseManifest.parse(signed(payload().put("android_play",JSONObject.NULL)),pem,now).release)
    }
    @Test fun onlySignedCompletedProductionPublicationIsAccepted(){
        val feed=PlayReleaseManifest.parse(signed(payload().put("android_play",play())),pem,now)
        assertEquals("1.0.7",feed.release!!.version);assertEquals(107,feed.release!!.versionCode)
        for((field,value) in listOf("status" to "pending","track" to "internal","rollout" to "staged","package_id" to "other.app","version" to "1.0.9")){
            rejects{PlayReleaseManifest.parse(signed(payload().put("android_play",play().put(field,value))),pem,now)}
        }
    }
    @Test fun metadataCannotBeAddedWithoutResigningOrReboundAtSameSequence(){
        val original=PlayReleaseManifest.parse(signed(payload()),pem,now)
        val altered=JSONObject(signed(payload())).put("payload",Base64.getEncoder().encodeToString(payload().put("android_play",play()).toString().toByteArray())).toString()
        rejects{PlayReleaseManifest.parse(altered,pem,now)}
        val rebound=PlayReleaseManifest.parse(signed(payload().put("android_play",play())),pem,now)
        rejects{UpdateRules.sequence(rebound.verified.sequence,rebound.verified.digest,original.verified.sequence,original.verified.digest)}
    }
}
