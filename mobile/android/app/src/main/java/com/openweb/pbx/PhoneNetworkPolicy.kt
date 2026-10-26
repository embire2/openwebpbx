/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.json.JSONObject
import org.linphone.core.AccountParams
import org.linphone.core.Core
import java.net.URI
import java.util.Locale

/** Per-account defaults. Never changes a running Core or an existing account. */
object PhoneNetworkPolicy {
    const val DEFAULT_STUN="openweb.sip.openwebpbx.com:3478"
    private val fields=setOf("schema","media","stun_enabled","stun_server","ice_enabled","turn_enabled","upnp_enabled")
    private fun endpoint(value:String):String? = try {
        require(value.length in 1..260 && value==value.trim())
        val uri=URI("stun://$value");val host=uri.host?.lowercase(Locale.ROOT) ?: error("Missing STUN host")
        require(uri.userInfo==null && uri.query==null && uri.fragment==null && uri.path.isNullOrEmpty() && host.length<=253)
        require(host.split('.').all{it.matches(Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"))})
        if(host.all{it.isDigit() || it=='.'})require(host.split('.').let{parts->parts.size==4 && parts.all{it.toIntOrNull() in 0..255 && it.toInt().toString()==it}})
        val port=if(uri.port==-1)3478 else uri.port
        require(port in 1..65535)
        "$host:$port"
    }catch(_:Exception){null}
    /** Old servers/profiles and invalid metadata retain known safe defaults. */
    fun metadata(value:JSONObject?):JSONObject {
        val valid=value!=null && value.keys().asSequence().toSet()==fields && value.opt("schema")==1 &&
            value.opt("media")=="pbx" && value.opt("stun_enabled")==true &&
            listOf("ice_enabled","turn_enabled","upnp_enabled").all{value.opt(it)==false}
        val server=if(valid)endpoint(value!!.optString("stun_server")) ?: DEFAULT_STUN else DEFAULT_STUN
        return JSONObject().put("schema",1).put("media","pbx").put("stun_enabled",true).put("stun_server",server)
            .put("ice_enabled",false).put("turn_enabled",false).put("upnp_enabled",false)
    }
    fun configure(core:Core,params:AccountParams,value:JSONObject?) {
        val policy=core.createNatPolicy()
        policy.stunServer=metadata(value).getString("stun_server")
        policy.isStunEnabled=true;policy.isIceEnabled=false;policy.isTurnEnabled=false;policy.isUpnpEnabled=false
        params.natPolicy=policy
    }
}
