/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.json.JSONObject
import java.time.Instant

data class AndroidRelease(val version:String,val sequence:Long,val digest:String,val envelope:String,val url:String,val bytes:Long,val sha256:String,val versionCode:Long,val minimumServer:String,val minimumSdk:Int,val expires:Long)
object ReleaseManifest {
    fun parse(envelope:String,pem:String,now:Long=System.currentTimeMillis()):AndroidRelease {
        require(envelope.toByteArray().size<=UpdateRules.MAX_ENVELOPE)
        val outer=JSONObject(envelope);require(outer.getString("key_id")==UpdateRules.KEY_ID)
        val bytes=UpdateRules.verify(outer.getString("payload"),outer.getString("signature"),pem)
        val payload=JSONObject(String(bytes,Charsets.UTF_8))
        require(payload.getInt("schema")==1 && payload.getString("product")=="openwebpbx" && payload.getString("channel")=="stable")
        val version=payload.getString("version");UpdateRules.version(version)
        val published=Instant.parse(payload.getString("published_at")).toEpochMilli();val expires=Instant.parse(payload.getString("expires_at")).toEpochMilli()
        require(published<=now+300000 && expires>now && expires>published && expires-published<=366L*86400000)
        val sequence=payload.getLong("sequence");require(sequence>0)
        val assets=payload.getJSONArray("assets");require(assets.length() in 1..32)
        val candidates=(0 until assets.length()).map{assets.getJSONObject(it)}.filter{it.optString("platform")=="android-universal"};require(candidates.size==1)
        val asset=candidates.single();val name="openwebpbx-$version-android.apk";val url=asset.getString("url")
        require(asset.getString("name")==name && UpdateRules.trustedUrl(url,version,name))
        require(asset.getString("package_id")==UpdateRules.PACKAGE && asset.getString("certificate_sha256")==UpdateRules.CERTIFICATE)
        val size=asset.getLong("bytes");require(size in 1..UpdateRules.MAX_APK)
        val hash=asset.getString("sha256");require(hash.matches(Regex("[a-f0-9]{64}")))
        val code=asset.getLong("version_code");require(code in 1..Int.MAX_VALUE.toLong())
        val minimum=asset.getString("minimum_server_version");UpdateRules.version(minimum)
        val sdk=asset.getInt("min_sdk");require(sdk in 28..100)
        return AndroidRelease(version,sequence,UpdateRules.sha256(bytes),envelope,url,size,hash,code,minimum,sdk,expires)
    }
}
