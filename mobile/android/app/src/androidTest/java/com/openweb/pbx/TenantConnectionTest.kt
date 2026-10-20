package com.openweb.pbx

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TenantConnectionTest {
    private val domain="00000000-0000-4000-a000-000000000118"
    private fun legacy()=JSONObject().put("server","https://old.example.com").put("token","x".repeat(64)).put("device_id","device-original")
        .put("profile_id","original-profile").put("profile_name","Original account")
        .put("account",JSONObject().put("extension","1000"))
        .put("sip",JSONObject().put("domain","original-sip-realm.example.com").put("username","original-login").put("password","private-original").put("server","old.example.com").put("port",5061).put("transport","tls").put("media_encryption","srtp"))
        .put("pending_calls",JSONArray().put(JSONObject().put("id","old-history")))
    private fun proof()=JSONObject().put("schema",1).put("hostname","alpha.openwebpbx.com").put("serverOrigin","https://old.example.com").put("domainUuid",domain).put("revision",1)
    private fun bootstrap()=JSONObject().put("device_id","device-original").put("account",JSONObject().put("extension","1000").put("domain_uuid",domain))
        .put("sip",JSONObject().put("domain","original-sip-realm.example.com").put("username","original-login"))
    @Test fun legacyAccountsCannotConsumeTheirTokenBeforeConfirmation(){
        val saved=legacy();assertFalse(TenantConnection.ready(saved));assertFalse(TenantConnection.confirmed(saved))
        try{PhoneApi.profile(saved);fail("Legacy token was eligible for network use")}catch(_:IllegalArgumentException){}
        var fetched=0;ProfileUpdatePolicy.load(listOf(saved),fetch={fetched++;error("No network is permitted")});assertEquals(0,fetched)
        assertEquals("private-original",saved.getJSONObject("sip").getString("password"))
    }
    @Test fun oldAllowedAliasStillRequiresExplicitEntryOnce(){
        val saved=legacy().put("server","https://alpha.openwebpbx.com")
        assertFalse(TenantConnection.ready(saved));try{PhoneApi.profile(saved);fail()}catch(_:IllegalArgumentException){}
        assertTrue(TenantConnection.ready(TenantConnection.candidate(saved,"https://alpha.openwebpbx.com",proof())))
    }
    @Test fun custodianProofMustBindTheExactRecipientAndTenant(){
        for(change in listOf("serverOrigin","hostname","domainUuid","revision")){
            val saved=legacy().apply{getJSONObject("account").put("domain_uuid",domain)};val altered=proof()
            when(change){"serverOrigin"->altered.put(change,"https://another.example.com");"hostname"->altered.put(change,"beta.openwebpbx.com");"domainUuid"->altered.put(change,"foreign-domain");else->altered.put(change,0)}
            try{TenantConnection.candidate(saved,"https://alpha.openwebpbx.com",altered);fail(change)}catch(_:IllegalArgumentException){}
        }
    }
    @Test fun successfulRebindPreservesSecretsProfileAndPendingHistory(){
        val before=legacy();val original=before.toString();val candidate=TenantConnection.candidate(before,"https://alpha.openwebpbx.com",proof())
        assertEquals(original,before.toString());val completed=TenantConnection.complete(candidate,bootstrap())
        for(key in listOf("token","device_id","profile_id","profile_name","sip","pending_calls"))assertEquals(before.get(key).toString(),completed.get(key).toString())
        assertEquals("https://alpha.openwebpbx.com",completed.getString("server"));assertTrue(TenantConnection.ready(completed))
    }
    @Test fun wrongAccountBootstrapCannotCommitTheMigration(){
        for(key in listOf("device_id","username","domain","extension","domain_uuid")){
            val candidate=TenantConnection.candidate(legacy(),"https://alpha.openwebpbx.com",proof());val response=bootstrap()
            when(key){"device_id"->response.put(key,"foreign");"username","domain"->response.getJSONObject("sip").put(key,"foreign");else->response.getJSONObject("account").put(key,"foreign")}
            try{TenantConnection.complete(candidate,response);fail(key)}catch(_:IllegalArgumentException){}
        }
    }
    @Test fun aCloneWithTheSameSipRealmCannotMergeHistoryAcrossInstances(){
        val fresh=legacy().put("server","https://alpha.openwebpbx.com").apply{getJSONObject("account").put("domain_uuid",domain)}
        assertTrue(TenantConnection.sameRestoredAccount(legacy(),fresh,proof()))
        assertFalse(TenantConnection.sameRestoredAccount(legacy().put("server","https://foreign.example.com"),fresh,proof()))
        assertFalse(TenantConnection.sameRestoredAccount(legacy().apply{getJSONObject("account").put("domain_uuid","foreign")},fresh,proof()))
    }
    @Test fun revocationDoesNotEraseConfirmedAddressButBlocksNetworkUse(){
        val profile=TenantConnection.confirm(legacy(),"https://alpha.openwebpbx.com").put("needs_login",true)
        assertTrue(TenantConnection.confirmed(profile));assertFalse(TenantConnection.ready(profile))
        try{PhoneApi.profile(profile);fail()}catch(_:IllegalArgumentException){}
    }
    @Test fun eachSavedAccountNeedsItsOwnConfirmation(){
        val first=TenantConnection.confirm(legacy(),"https://alpha.openwebpbx.com")
        val second=legacy().put("profile_id","second-profile")
        assertEquals(listOf(first),ProfileUpdatePolicy.active(listOf(first,second)))
        assertFalse(TenantConnection.ready(second));assertEquals("https://old.example.com",second.getString("server"))
    }
}
