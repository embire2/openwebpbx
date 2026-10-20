package com.openweb.pbx
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.IOException
@RunWith(AndroidJUnit4::class)
class ProfileUpdatePolicyTest {
    private fun profile(id:String)=TenantConnection.confirm(JSONObject().put("profile_id",id).put("token","token-$id"),"https://$id.openwebpbx.com")
    private fun policy(mode:String,server:String="1.0.16")=JSONObject().put("schema",1).put("channel","stable").put("feed_url",UpdateRules.FEED).put("mode",mode).put("server_version",server)
    @Test fun offlineTenantDoesNotDiscardAnotherRequiredRule(){
        val profiles=listOf(profile("a"),profile("b"));val result=ProfileUpdatePolicy.load(profiles,fetch={if(it.getString("profile_id")=="b")throw IOException() else policy("required")})
        assertEquals("required",result.mode);assertTrue(result.trusted);assertEquals("0.0.0",result.oldestServer);assertEquals(1,result.unavailable)
    }
    @Test fun cachedAuthenticatedCompatibilityAllowsOtherRequiredRuleToProceed(){
        val a=profile("a");val b=profile("b");val now=100000000L
        ProfileUpdatePolicy.load(listOf(b),cache={_,cache->b.put("update_policy",cache)},now=now,fetch={policy("notify")})
        val result=ProfileUpdatePolicy.load(listOf(a,b),now=now+1000,fetch={if(it.getString("profile_id")=="b")throw IOException() else policy("required")})
        assertEquals("required",result.mode);assertTrue(result.trusted);assertEquals("1.0.16",result.oldestServer)
    }
    @Test fun revokedAccountCannotBlockOtherTenantsRequiredUpdate(){
        val a=profile("a");val b=profile("b");val revoked=mutableListOf<String>()
        val result=ProfileUpdatePolicy.load(listOf(a,b),revoke={revoked.add(it)},fetch={if(it.getString("profile_id")=="b")throw ApiError(401,"revoked") else policy("required")})
        assertEquals(listOf("b"),revoked);assertTrue(b.getBoolean("needs_login"));assertEquals("required",result.mode);assertEquals("1.0.16",result.oldestServer);assertEquals(ProfileUpdatePolicy.identity(listOf(a)),result.identity)
    }
    @Test fun staleOrDifferentTokenCacheCannotClaimCompatibility(){
        val b=profile("b");val now=100000000L
        ProfileUpdatePolicy.load(listOf(b),cache={_,cache->b.put("update_policy",cache)},now=now,fetch={policy("required")})
        val stale=ProfileUpdatePolicy.load(listOf(b),now=now+ProfileUpdatePolicy.CACHE_LIFETIME+1,fetch={throw IOException()});assertFalse(stale.trusted);assertEquals("0.0.0",stale.oldestServer)
        b.put("token","replacement-token");val replaced=ProfileUpdatePolicy.load(listOf(b),now=now+1,fetch={throw IOException()});assertFalse(replaced.trusted);assertEquals("0.0.0",replaced.oldestServer)
    }
    @Test fun unknownFeedFromOneTenantDoesNotEraseAnotherRequiredRule(){
        val result=ProfileUpdatePolicy.load(listOf(profile("a"),profile("b")),fetch={if(it.getString("profile_id")=="a")policy("required") else policy("notify").put("feed_url","https://wrong.example.invalid")})
        assertEquals("required",result.mode);assertTrue(result.trusted);assertEquals("0.0.0",result.oldestServer)
    }
}
