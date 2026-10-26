/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.json.JSONObject
import java.net.URI
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/** Local encrypted confirmation is deliberately separate from token validity. */
object TenantConnection {
    const val POLICY=1
    private const val REGISTRY="https://domains.openwebpbx.com/v1/tenant-addresses/"
    fun confirmed(profile:JSONObject):Boolean = try {
        profile.optInt("tenant_url_policy")==POLICY &&
            Enrollment.server(profile.getString("server"))==profile.optString("tenant_url_confirmed")
    }catch(_:Exception){false}
    fun ready(profile:JSONObject):Boolean = !profile.optBoolean("needs_login") && confirmed(profile)
    fun confirm(profile:JSONObject,server:String):JSONObject = profile.apply {
        val origin=Enrollment.server(server)
        put("server",origin);put("tenant_url_confirmed",origin);put("tenant_url_policy",POLICY)
    }
    /** QR and setup files already carry the URL; successful setup confirms it. */
    fun bindSetup(profile:JSONObject,proof:JSONObject,expectedExtension:String?=null):JSONObject {
        require(ready(profile)){"The phone connection has no verified tenant address."}
        val origin=Enrollment.server(profile.getString("server"))
        val domain=proof.getString("domainUuid")
        require(proof.getInt("schema")==1 && proof.getString("hostname")==URI(origin).host && proof.getLong("revision")>0 &&
            domain.matches(Regex("[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}"))){"This tenant address could not be verified."}
        val canonical=legacyOrigin(proof.getString("serverOrigin"));val account=profile.getJSONObject("account")
        require(account.getString("domain_uuid")==domain){"This connection belongs to another tenant."}
        require(account.getString("extension_uuid").matches(Regex("[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}"))){"The PBX returned an invalid phone account."}
        require(expectedExtension==null || account.getString("extension")==expectedExtension){"This setup code belongs to a different extension. Ask your administrator for a new QR code."}
        return profile.put("tenant_instance_origin",canonical).put("tenant_domain_uuid",domain)
    }
    private fun legacyOrigin(raw:String):String {
        val u=URI(raw)
        require(u.scheme.equals("https",true) && !u.host.isNullOrEmpty() && u.userInfo==null &&
            u.query==null && u.fragment==null && (u.path.isNullOrEmpty()||u.path=="/") && u.port in listOf(-1,443))
        return "https://"+u.host.lowercase(java.util.Locale.ROOT)
    }
    /** Resolve only at the fixed custodian origin; never send a phone token. */
    fun lookup(server:String):JSONObject {
        val host=URI(Enrollment.server(server)).host
        val connection=URL(REGISTRY+host).openConnection() as HttpsURLConnection
        try {
            connection.connectTimeout=12000;connection.readTimeout=12000;connection.instanceFollowRedirects=false
            connection.setRequestProperty("Accept","application/json")
            require(connection.responseCode==200){"This tenant address is not ready. Check it with your administrator and try again."}
            require(connection.contentLengthLong<=4096)
            val bytes=connection.inputStream.use{input->
                val out=java.io.ByteArrayOutputStream();val buffer=ByteArray(1024)
                while(true){val count=input.read(buffer);if(count<0)break;require(out.size()+count<=4096);out.write(buffer,0,count)}
                out.toByteArray()
            }
            val proof=JSONObject(String(bytes,Charsets.UTF_8))
            require(proof.getInt("schema")==1 && proof.getString("hostname")==host && proof.getLong("revision")>0)
            require(proof.getString("domainUuid").matches(Regex("[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}")))
            legacyOrigin(proof.getString("serverOrigin"))
            return proof
        }finally{connection.disconnect()}
    }
    /** Never infer recipient ownership from a shared IP or response metadata. */
    fun candidate(saved:JSONObject,server:String,proof:JSONObject):JSONObject {
        val origin=Enrollment.server(server)
        require(proof.getInt("schema")==1 && proof.getString("hostname")==URI(origin).host && proof.getLong("revision")>0)
        val original=legacyOrigin(saved.getString("server"));val canonical=legacyOrigin(proof.getString("serverOrigin"))
        val previouslyVerified=saved.optString("tenant_instance_origin").takeIf{saved.optInt("tenant_url_policy")==POLICY && it.isNotBlank()}
        require(original==origin || original==canonical || previouslyVerified==canonical){
            "This address belongs to a different PBX. Ask your administrator for a new connection QR code."
        }
        val domain=saved.optJSONObject("account")?.optString("domain_uuid").orEmpty()
        require(domain.isBlank() || domain==proof.getString("domainUuid")){"Enter the address for this account's tenant."}
        return confirm(JSONObject(saved.toString()),origin).put("tenant_instance_origin",canonical).put("tenant_domain_uuid",proof.getString("domainUuid"))
    }
    fun complete(candidate:JSONObject,response:JSONObject):JSONObject {
        val old=candidate.getJSONObject("sip");val fresh=response.getJSONObject("sip")
        require(response.getString("device_id")==candidate.getString("device_id") &&
            fresh.getString("username")==old.getString("username") && fresh.getString("domain")==old.getString("domain") &&
            response.getJSONObject("account").getString("extension")==candidate.getJSONObject("account").getString("extension") &&
            response.getJSONObject("account").getString("domain_uuid")==candidate.getString("tenant_domain_uuid")){
            "The tenant address does not match this saved phone account."
        }
        // Keep the entire original SIP tuple, device/token, pending history and
        // profile ID. Bootstrap metadata cannot replace their secret or realm.
        candidate.put("account",response.getJSONObject("account"))
        response.optJSONArray("features")?.let{candidate.put("features",it)}
        response.optJSONObject("push")?.let{candidate.put("push",it)}
        response.optJSONObject("network")?.let{candidate.put("network",PhoneNetworkPolicy.metadata(it))}
        candidate.remove("update_policy")
        return candidate
    }
    fun sameRestoredAccount(saved:JSONObject,fresh:JSONObject,proof:JSONObject):Boolean = try {
        // A SIP realm and extension can also exist on another installation.
        // Match the custodian-verified recipient before preserving local history.
        val original=legacyOrigin(saved.getString("server"));val canonical=legacyOrigin(proof.getString("serverOrigin"))
        val verified=saved.optString("tenant_instance_origin").takeIf{saved.optInt("tenant_url_policy")==POLICY}
        val domain=saved.getJSONObject("account").optString("domain_uuid")
        (original==canonical || original==Enrollment.server(fresh.getString("server")) || verified==canonical) &&
            (domain.isBlank() || domain==proof.getString("domainUuid")) &&
            fresh.getJSONObject("account").getString("domain_uuid")==proof.getString("domainUuid") &&
            saved.getJSONObject("account").getString("extension")==fresh.getJSONObject("account").getString("extension") &&
            saved.getJSONObject("sip").getString("domain")==fresh.getJSONObject("sip").getString("domain")
    }catch(_:Exception){false}
}
