/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.json.JSONObject

/** One app binary serves every tenant: selection must never weaken an update rule. */
object ProfileUpdatePolicy {
    const val CACHE_LIFETIME=24*60*60*1000L
    data class Result(val mode:String,val oldestServer:String?,val trusted:Boolean,val identity:String,val unavailable:Int=0)
    fun active(profiles:List<JSONObject>)=profiles.filter{!it.optBoolean("needs_login")}
    private fun binding(profile:JSONObject)=UpdateRules.sha256((profile.getString("server")+"\u0000"+profile.getString("token")).toByteArray(Charsets.UTF_8))
    fun identity(profiles:List<JSONObject>):String = if(active(profiles).isEmpty())"" else UpdateRules.sha256(active(profiles).map{it.getString("profile_id")+"\u0000"+binding(it)}.sorted().joinToString("\u0001").toByteArray(Charsets.UTF_8))
    fun strongest(modes:List<String>):String {
        require(modes.all{it in listOf("notify","download","required")})
        return when{ "required" in modes->"required";"download" in modes->"download";else->"notify" }
    }
    private fun validate(policy:JSONObject){
        require(policy.getInt("schema")==1 && policy.getString("channel")=="stable" && policy.getString("feed_url")==UpdateRules.FEED)
        UpdateRules.policyMode(policy.getString("mode"),policy.optString("tenant_mode").takeIf{it.isNotEmpty()},policy.optString("minimum_version").takeIf{it.isNotEmpty()},BuildConfig.VERSION_NAME)
        UpdateRules.version(policy.getString("server_version"))
    }
    fun load(profiles:List<JSONObject>,cache:(String,JSONObject)->Unit={_,_->},revoke:(String)->Unit={},now:Long=System.currentTimeMillis(),fetch:(JSONObject)->JSONObject={PhoneApi(it.getString("server"),it.getString("token")).json("updates")}):Result {
        val modes=mutableListOf<String>();val versions=mutableListOf<String>();var trusted=false;var unavailable=0
        for(profile in active(profiles)) {
            val id=profile.getString("profile_id")
            var policy:JSONObject?=null
            try {
                policy=fetch(profile);validate(policy)
                val saved=JSONObject().put("checked",now).put("binding",binding(profile)).put("policy",policy)
                cache(id,saved)
            }catch(e:Exception){
                if(e is ApiError && e.status in listOf(401,403)){
                    // This authenticated connection is no longer allowed. Keep its
                    // profile for sign-in recovery, without blocking other tenants.
                    profile.put("needs_login",true);revoke(id);continue
                }
                unavailable++
                policy=null
                val old=profile.optJSONObject("update_policy")
                if(old!=null)try{
                    val checked=old.getLong("checked")
                    require(old.getString("binding")==binding(profile) && checked<=now+30000 && now-checked<=CACHE_LIFETIME)
                    policy=old.getJSONObject("policy");validate(policy!!)
                }catch(_:Exception){policy=null}
                if(policy==null){versions.add("0.0.0");continue} // Unknown compatibility: hold installation, retain other trusted rules.
            }
            val verified=policy ?: continue
            modes.add(UpdateRules.policyMode(verified.getString("mode"),verified.optString("tenant_mode").takeIf{it.isNotEmpty()},verified.optString("minimum_version").takeIf{it.isNotEmpty()},BuildConfig.VERSION_NAME))
            versions.add(verified.getString("server_version"));trusted=true
        }
        return Result(strongest(modes),versions.minWithOrNull{a,b->UpdateRules.compare(a,b)},trusted,identity(profiles),unavailable)
    }
}
