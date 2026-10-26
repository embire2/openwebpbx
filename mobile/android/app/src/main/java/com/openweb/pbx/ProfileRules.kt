/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.json.JSONObject
import java.net.URI

object ProfileRules {
    const val MAX_PROFILES=10
    const val MAX_SETUP_BYTES=16384
    fun appPassword(value:String):Boolean=value.codePointCount(0,value.length) in 12..128 && value.codePoints().noneMatch{it in 0xD800..0xDFFF}
    fun label(profile:JSONObject):String = profile.optString("profile_name").ifBlank {
        val a=profile.optJSONObject("account")
        val tenant=a?.optString("tenant_name").orEmpty().ifBlank{URI(profile.getString("server")).host}
        "$tenant · ${a?.optString("extension").orEmpty()}"
    }
    fun sameAccount(a:JSONObject,b:JSONObject):Boolean {
        val left=a.getJSONObject("account");val right=b.getJSONObject("account")
        val sameIds=left.optString("domain_uuid").isNotBlank() && left.optString("extension_uuid").isNotBlank() && left.optString("domain_uuid")==right.optString("domain_uuid") && left.optString("extension_uuid")==right.optString("extension_uuid")
        // Also recognise a migrated account whose older server omitted UUIDs.
        val sameSip=a.optJSONObject("sip")?.optString("domain")?.lowercase()==b.optJSONObject("sip")?.optString("domain")?.lowercase() && left.optString("extension")==right.optString("extension")
        val noConflictingIds=listOf("domain_uuid","extension_uuid").all{key->left.optString(key).isBlank() || right.optString(key).isBlank() || left.optString(key)==right.optString(key)}
        return a.optString("server").equals(b.optString("server"),true) && noConflictingIds && (sameIds || sameSip)
    }
    /** A verified fresh QR can replace only its own disconnected saved account. */
    fun reconnectTarget(profiles:List<JSONObject>,fresh:JSONObject,proof:JSONObject):JSONObject? {
        val matches=profiles.filter{
            val left=it.getJSONObject("account");val right=fresh.getJSONObject("account")
            val noConflictingIds=listOf("domain_uuid","extension_uuid").all{key->left.optString(key).isBlank() || right.optString(key).isBlank() || left.optString(key)==right.optString(key)}
            noConflictingIds && (sameAccount(it,fresh) || (!TenantConnection.ready(it) && TenantConnection.sameRestoredAccount(it,fresh,proof)))
        }
        require(matches.size<=1){"More than one saved account matches. Remove an unused copy in Accounts, then try again."}
        val match=matches.singleOrNull()
        require(match==null || !TenantConnection.ready(match)){"This account is already saved. Open Accounts to edit or reconnect it."}
        return match
    }
    fun setup(raw:String):JSONObject {
        require(raw.toByteArray(Charsets.UTF_8).size<=MAX_SETUP_BYTES){"That setup file is too large"}
        val data=JSONObject(raw)
        require(data.optString("type")=="openwebpbx" && data.optInt("version")==1){"Choose an OpenWeb PBX setup file or QR code"}
        require(!data.has("password") && !data.has("sip") && !data.has("token")){"Setup files must contain a one-use connection code, not a password"}
        val allowed=setOf("type","version","server","code","extension")
        require(data.keys().asSequence().all{it in allowed}){"This setup file has unsupported details"}
        val result=JSONObject().put("type","openwebpbx").put("version",1).put("server",Enrollment.server(data.getString("server"))).put("code",Enrollment.code(data.getString("code")))
        data.optString("extension").takeIf{it.isNotBlank()}?.let{require(it.matches(Regex("[0-9]{1,16}"))){"The setup file's extension is invalid"};result.put("extension",it)}
        return result
    }
    fun connected(response:JSONObject,server:String):JSONObject {
        require(response.getString("token").length>=32 && response.getString("device_id").isNotBlank()){ "The PBX returned an invalid phone connection" }
        val sip=response.getJSONObject("sip")
        require(sip.getString("transport").equals("tls",true) && sip.getString("media_encryption").equals("srtp",true)){"Your PBX needs secure phone connections enabled"}
        for(key in listOf("username","password","domain","server"))require(sip.getString(key).isNotBlank()){"Your PBX returned incomplete phone details"}
        require(sip.optInt("port",5061) in 1..65535)
        response.getJSONObject("account").getString("extension")
        // Do not move a bearer token to a response-supplied origin. The user approved
        // this HTTPS host; canonical server identifiers remain account metadata.
        response.remove("tenant_instance_origin");response.remove("tenant_domain_uuid")
        response.put("network",PhoneNetworkPolicy.metadata(response.optJSONObject("network")))
        return TenantConnection.confirm(response,server)
    }
    fun canChange(activeCalls:Int,installing:Boolean):Boolean=activeCalls==0 && !installing
}
