/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class QrSetupRulesTest {
    private val domain="11111111-1111-1111-1111-111111111111"
    private val extension="22222222-2222-2222-2222-222222222222"
    private val origin="https://alpha.openwebpbx.com"
    private fun proof()=JSONObject().put("schema",1).put("hostname","alpha.openwebpbx.com").put("revision",1)
        .put("domainUuid",domain).put("serverOrigin","https://legacy.example.org")
    private fun response()=JSONObject().put("token","t".repeat(64)).put("device_id","new-device")
        .put("account",JSONObject().put("extension","1000").put("domain_uuid",domain).put("extension_uuid",extension))
        .put("sip",JSONObject().put("server","legacy.example.org").put("domain","preserved.realm")
            .put("username","owm-new").put("auth_username","owm-new").put("password","fixture-device-secret")
            .put("port",5061).put("transport","tls").put("media_encryption","srtp"))
    private fun connected()=TenantConnection.bindSetup(ProfileRules.connected(response(),origin),proof(),"1000")
    private fun legacy()=response().put("server","https://legacy.example.org").put("profile_id","saved-profile")
        .put("profile_name","My company").put("token","old-token").put("pending_calls",org.json.JSONArray().put("saved-history"))
    private fun refuses(block:()->Unit){try{block();fail("Invalid setup accepted")}catch(_:IllegalArgumentException){}}

    @Test fun qrSuppliesTenantUrlWithoutManualEntry(){
        val qr=JSONObject().put("type","openwebpbx").put("version",1).put("server",origin)
            .put("code","a".repeat(64)).put("extension","1000")
        val parsed=ProfileRules.setup(qr.toString())
        assertEquals(origin,parsed.getString("server"));assertEquals("a".repeat(64),parsed.getString("code"))
        val fresh=TenantConnection.bindSetup(ProfileRules.connected(response(),parsed.getString("server")),proof(),parsed.getString("extension"))
        assertTrue(TenantConnection.ready(fresh));assertEquals(origin,fresh.getString("tenant_url_confirmed"))
        assertEquals("https://legacy.example.org",fresh.getString("tenant_instance_origin"))
        assertEquals("owm-new",fresh.getJSONObject("sip").getString("username"))
    }
    @Test fun expiredOrReplayedCodeCannotBeMadeValidLocally(){
        // Parsing supplies transport details only; server enrollment remains the
        // sole consumer of the one-use code. No SIP credentials can enter a QR.
        val qr=JSONObject().put("type","openwebpbx").put("version",1).put("server",origin).put("code","a".repeat(64))
        for(key in listOf("sip","token","password"))refuses{ProfileRules.setup(JSONObject(qr.toString()).put(key,"injected").toString())}
        for(server in listOf("http://alpha.openwebpbx.com","https://evil.test","https://alpha.openwebpbx.com/path","https://user@alpha.openwebpbx.com"))
            refuses{ProfileRules.setup(JSONObject(qr.toString()).put("server",server).toString())}
    }
    @Test fun proofAndEncodedExtensionMustMatchTheRecipient(){
        for(key in listOf("hostname","domainUuid","revision","serverOrigin")){
            val altered=proof().put(key,when(key){"hostname"->"beta.openwebpbx.com";"domainUuid"->"33333333-3333-3333-3333-333333333333";"revision"->0;else->"http://legacy.example.org"})
            refuses{TenantConnection.bindSetup(ProfileRules.connected(response(),origin),altered,"1000")}
        }
        refuses{TenantConnection.bindSetup(ProfileRules.connected(response(),origin),proof(),"1050")}
        refuses{TenantConnection.bindSetup(ProfileRules.connected(response().apply{getJSONObject("account").put("extension_uuid","not-an-id")},origin),proof(),"1000")}
    }
    @Test fun trustedQrReplacesOnlyItsDisconnectedSavedAccount(){
        val saved=legacy();val before=saved.toString();val fresh=connected()
        assertSame(saved,ProfileRules.reconnectTarget(listOf(saved),fresh,proof()))
        assertEquals(before,saved.toString());assertFalse(TenantConnection.ready(saved))
        val other=legacy().put("server","https://other.example.org").apply{getJSONObject("account").put("domain_uuid","33333333-3333-3333-3333-333333333333")}
        assertNull(ProfileRules.reconnectTarget(listOf(other),fresh,proof()));assertEquals("old-token",other.getString("token"))
        refuses{ProfileRules.reconnectTarget(listOf(fresh),fresh,proof())}
        refuses{ProfileRules.reconnectTarget(listOf(saved,legacy()),fresh,proof())}
    }
    @Test fun conflictingIdsCannotMergeByMatchingSipRealm(){
        val first=connected();val other=connected().apply{getJSONObject("account").put("domain_uuid","33333333-3333-3333-3333-333333333333")}
        assertFalse(ProfileRules.sameAccount(first,other))
        other.getJSONObject("account").put("domain_uuid",domain).put("extension_uuid","33333333-3333-3333-3333-333333333333")
        assertFalse(ProfileRules.sameAccount(first,other))
        val old=connected().apply{getJSONObject("account").remove("extension_uuid")}
        assertTrue(ProfileRules.sameAccount(first,old))
    }
    @Test fun qrConfirmationNeverMutatesAnotherSavedProfile(){
        val old=legacy();val before=old.toString();val fresh=connected()
        assertTrue(TenantConnection.ready(fresh));assertEquals(before,old.toString())
        assertFalse(ProfileRules.canChange(1,false));assertFalse(ProfileRules.canChange(0,true))
        assertEquals("fixture-device-secret",old.getJSONObject("sip").getString("password"))
    }
    @Test fun restoredFallbackCannotOverrideConflictingKnownRecipientIds(){
        val fresh=connected()
        for(host in listOf(origin,"https://legacy.example.org"))for(key in listOf("domain_uuid","extension_uuid")){
            val saved=legacy().put("server",host).apply{getJSONObject("account").put(key,"33333333-3333-3333-3333-333333333333")}
            val before=saved.toString()
            assertFalse(ProfileRules.sameAccount(saved,fresh))
            assertNull("A known recipient UUID conflict must not reuse a saved profile",ProfileRules.reconnectTarget(listOf(saved),fresh,proof()))
            assertEquals(before,saved.toString())
        }
    }
    @Test fun genuineLegacyProfilesWithMissingIdsStillReconnectOnlyTheirOwnTenant(){
        val fresh=connected()
        for(missing in listOf(listOf("extension_uuid"),listOf("domain_uuid"),listOf("domain_uuid","extension_uuid"))){
            val saved=legacy().apply{for(key in missing)getJSONObject("account").remove(key)}
            val before=saved.toString()
            assertSame(saved,ProfileRules.reconnectTarget(listOf(saved),fresh,proof()))
            assertEquals(before,saved.toString())
        }
        val foreign=legacy().put("server","https://unrelated.example.org").apply{getJSONObject("account").remove("domain_uuid");getJSONObject("account").remove("extension_uuid")}
        assertNull(ProfileRules.reconnectTarget(listOf(foreign),fresh,proof()))
        refuses{ProfileRules.reconnectTarget(listOf(fresh),fresh,proof())}
    }
}
