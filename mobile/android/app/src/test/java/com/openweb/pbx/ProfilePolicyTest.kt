package com.openweb.pbx
import org.junit.Assert.*
import org.junit.Test
class ProfilePolicyTest {
    @Test fun tenantShortcutUsesOnlyAnHttpsOrigin(){
        assertEquals("https://alpha.openwebpbx.com",Enrollment.tenant("alpha"))
        assertEquals("https://alpha.example.org",Enrollment.tenant("alpha.example.org"))
        assertEquals("https://alpha.example.org:8443",Enrollment.tenant("https://alpha.example.org:8443/"))
        for(value in listOf("http://alpha.example.org","https://user:pass@alpha.example.org","alpha.example.org/other","../alpha","https://alpha.example.org?tenant=beta"))try{Enrollment.tenant(value);fail(value)}catch(_:IllegalArgumentException){}
    }
    @Test fun noProfileMutationWhileAnyConversationOrUpdateIsOpen(){
        assertTrue(ProfileRules.canChange(0,false))
        for(calls in listOf(1,2,3))assertFalse(ProfileRules.canChange(calls,false))
        assertFalse(ProfileRules.canChange(0,true))
    }
    @Test fun allTenantPoliciesApplyIndependentOfSelection(){
        for(modes in listOf(listOf("notify","required"),listOf("required","notify"),listOf("download","required","notify")))assertEquals("required",ProfileUpdatePolicy.strongest(modes))
        assertEquals("download",ProfileUpdatePolicy.strongest(listOf("notify","download")))
        assertEquals("notify",ProfileUpdatePolicy.strongest(emptyList()))
        assertEquals("notify",ProfileUpdatePolicy.strongest(listOf("notify","notify")))
        try{ProfileUpdatePolicy.strongest(listOf("required","disabled"));fail()}catch(_:IllegalArgumentException){}
    }
    @Test fun appPasswordsCountUnicodeCharactersWithoutNormalizing(){
        assertFalse(ProfileRules.appPassword("😀".repeat(6)))
        assertTrue(ProfileRules.appPassword("😀".repeat(12)))
        assertTrue(ProfileRules.appPassword("é".repeat(128)))
        assertFalse(ProfileRules.appPassword("é".repeat(129)))
        assertTrue(ProfileRules.appPassword("e\u0301".repeat(6)))
        assertFalse(ProfileRules.appPassword("a".repeat(12)+"\uD800"))
    }
}
