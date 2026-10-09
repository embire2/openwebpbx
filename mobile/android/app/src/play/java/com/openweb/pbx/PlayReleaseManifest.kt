/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.json.JSONObject
import java.time.Instant
import java.util.Base64

data class PlayRelease(val version:String,val versionCode:Long,val minimumServer:String,val minimumSdk:Int,val published:Long,val expires:Long)
data class PlayFeed(val verified:AndroidRelease,val release:PlayRelease?)

/** A GitHub APK announcement alone never establishes Google Play availability. */
object PlayReleaseRules {
    fun published(status:String,track:String,rollout:String)=status=="published" && track=="production" && rollout=="complete"
    fun validate(release:PlayRelease,feedVersion:String,feedPublished:Long,now:Long) {
        UpdateRules.version(release.version);UpdateRules.version(release.minimumServer)
        require(UpdateRules.compare(release.version,feedVersion)<=0)
        require(release.versionCode in 1..Int.MAX_VALUE.toLong() && release.minimumSdk in 28..100)
        require(release.published>=0 && release.published<=feedPublished && release.published<=now+300000 && release.expires>now)
    }
    fun newer(release:PlayRelease,installedVersion:String,installedCode:Long)=release.versionCode>installedCode && UpdateRules.compare(release.version,installedVersion)>0
    fun supported(release:PlayRelease,sdk:Int,serverVersion:String?)=sdk>=release.minimumSdk && (serverVersion==null || UpdateRules.compare(serverVersion,release.minimumServer)>=0)
    fun policyFresh(checked:Long,now:Long,storedAccount:String,currentAccount:String)=storedAccount.isNotEmpty() && storedAccount==currentAccount && checked<=now+300000 && now-checked<24*60*60*1000L
}

object PlayReleaseManifest {
    fun parse(envelope:String,pem:String,now:Long=System.currentTimeMillis()):PlayFeed {
        // Reuse the pinned signature, expiry, product, channel and bounded feed checks.
        // The validated direct APK is never downloaded or installed by this provider.
        val verified=ReleaseManifest.parse(envelope,pem,now)
        val payload=JSONObject(String(Base64.getDecoder().decode(JSONObject(envelope).getString("payload")),Charsets.UTF_8))
        if(!payload.has("android_play") || payload.isNull("android_play"))return PlayFeed(verified,null)
        val play=payload.getJSONObject("android_play")
        require(play.keys().asSequence().toSet()==setOf("status","track","rollout","package_id","version","version_code","minimum_server_version","min_sdk","published_at"))
        require(PlayReleaseRules.published(play.getString("status"),play.getString("track"),play.getString("rollout")))
        require(play.getString("package_id")==UpdateRules.PACKAGE)
        require(play.get("version_code") is Int || play.get("version_code") is Long)
        require(play.get("min_sdk") is Int)
        require(play.getString("published_at").matches(Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z")))
        val release=PlayRelease(play.getString("version"),play.getLong("version_code"),play.getString("minimum_server_version"),play.getInt("min_sdk"),Instant.parse(play.getString("published_at")).toEpochMilli(),verified.expires)
        PlayReleaseRules.validate(release,verified.version,Instant.parse(payload.getString("published_at")).toEpochMilli(),now)
        return PlayFeed(verified,release)
    }
}
