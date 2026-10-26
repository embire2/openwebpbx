/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.linphone.core.AccountParams
import org.linphone.core.Core
import org.linphone.core.NatPolicy
import java.lang.reflect.Proxy

class PhoneNetworkPolicyTest {
    @Test fun oldProfilesAndServersReceiveSafeDefaults(){
        val value=PhoneNetworkPolicy.metadata(null)
        assertEquals(PhoneNetworkPolicy.DEFAULT_STUN,value.getString("stun_server"))
        assertEquals("pbx",value.getString("media"));assertTrue(value.getBoolean("stun_enabled"))
        for(key in listOf("ice_enabled","turn_enabled","upnp_enabled"))assertFalse(value.getBoolean(key))
    }
    @Test fun configuredHostAndPortAreNormalized(){
        for((input,expected) in listOf("STUN.EXAMPLE.ORG" to "stun.example.org:3478","stun.example.org:3479" to "stun.example.org:3479","192.0.2.10:3478" to "192.0.2.10:3478")){
            assertEquals(expected,PhoneNetworkPolicy.metadata(PhoneNetworkPolicy.metadata(null).put("stun_server",input)).getString("stun_server"))
        }
    }
    @Test fun unsafeOrUnsupportedMetadataCannotBreakCallingDefaults(){
        for(input in listOf("https://evil.test","user:password@evil.test","evil.test/path","evil.test?secret=x","evil.test:0","evil.test:65536","evil.test\r\n","999.999.999.999","evil.test.","[::1]:3478"))
            assertEquals(PhoneNetworkPolicy.DEFAULT_STUN,PhoneNetworkPolicy.metadata(PhoneNetworkPolicy.metadata(null).put("stun_server",input)).getString("stun_server"))
        for((key,value) in listOf("media" to "direct","turn_enabled" to true,"ice_enabled" to true,"upnp_enabled" to true,"stun_enabled" to false,"schema" to 2,"password" to "unwanted")){
            val input=PhoneNetworkPolicy.metadata(null).put("stun_server","custom.example.org:3478").put(key,value)
            assertEquals(PhoneNetworkPolicy.DEFAULT_STUN,PhoneNetworkPolicy.metadata(input).getString("stun_server"))
        }
    }
    @Suppress("UNCHECKED_CAST")
    private fun <T> adapter(type:Class<T>,call:(String,Array<out Any?>?)->Any?):T =
        Proxy.newProxyInstance(type.classLoader,arrayOf(type)){_,method,args->call(method.name,args)} as T
    @Test fun sdkPolicyIsSetOnOnlyTheNewAccount(){
        // Actual SDK interfaces with controlled method adapters; no native calls.
        val actions=mutableListOf<Pair<String,Any?>>()
        val policy=adapter(NatPolicy::class.java){name,args->actions+=name to args?.singleOrNull();null}
        val core=adapter(Core::class.java){name,_->check(name=="createNatPolicy");actions+=name to null;policy}
        val params=adapter(AccountParams::class.java){name,args->check(name=="setNatPolicy");assertSame(policy,args!![0]);actions+=name to null;null}
        PhoneNetworkPolicy.configure(core,params,null)
        assertEquals(listOf("createNatPolicy","setStunServer","setStunEnabled","setIceEnabled","setTurnEnabled","setUpnpEnabled","setNatPolicy"),actions.map{it.first})
        assertEquals(PhoneNetworkPolicy.DEFAULT_STUN,actions[1].second)
        assertEquals(true,actions[2].second);for(index in 3..5)assertEquals(false,actions[index].second)
    }
}
