/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.linphone.core.Factory

/** Explicit empty qualification app only. Core is never started and has no account. */
@RunWith(AndroidJUnit4::class)
class NativeStunPolicyTest {
    @Test fun actualSdkPoliciesRemainAccountLocalWithoutStartingConnections(){
        val inst=InstrumentationRegistry.getInstrumentation();val context=inst.targetContext
        require(InstrumentationRegistry.getArguments().getString("qrSetupIsolated")=="true")
        require(PhoneStore(context).profiles().isEmpty() && PhoneService.instance==null)
        val factory=Factory.instance()
        val config=factory.createConfigFromString("[sip]\nstore_auth_info=0\nsip_port=-1\nsip_tcp_port=-1\nsip_tls_port=-1\n[storage]\nbackend=null\n")
        val core=factory.createCoreWithConfig(config,context)
        try{
            core.setNetworkReachable(false)
            assertTrue(core.accountList.isEmpty())
            val global=core.natPolicy
            val before=listOf(global?.nativePointer,global?.stunServer,global?.isStunEnabled,global?.isIceEnabled,global?.isTurnEnabled,global?.isUpnpEnabled)
            val first=core.createAccountParams();val second=core.createAccountParams()
            PhoneNetworkPolicy.configure(core,first,null)
            val other=PhoneNetworkPolicy.metadata(null).put("stun_server","stun-qr120.openwebpbx.com:3478")
            PhoneNetworkPolicy.configure(core,second,other)
            val a=requireNotNull(first.natPolicy);val b=requireNotNull(second.natPolicy)
            assertEquals(PhoneNetworkPolicy.DEFAULT_STUN,a.stunServer)
            assertEquals("stun-qr120.openwebpbx.com:3478",b.stunServer)
            assertNotEquals(a.nativePointer,b.nativePointer)
            for(policy in listOf(a,b)){assertTrue(policy.isStunEnabled);assertFalse(policy.isIceEnabled);assertFalse(policy.isTurnEnabled);assertFalse(policy.isUpnpEnabled)}
            val after=core.natPolicy
            assertEquals(before,listOf(after?.nativePointer,after?.stunServer,after?.isStunEnabled,after?.isIceEnabled,after?.isTurnEnabled,after?.isUpnpEnabled))
            assertTrue(core.accountList.isEmpty())
            assertTrue(PhoneStore(context).profiles().isEmpty())
            assertNull(PhoneService.instance)
        }finally{core.stop()}
    }
}
