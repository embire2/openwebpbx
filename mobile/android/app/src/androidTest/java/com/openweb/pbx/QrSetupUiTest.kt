/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.app.Activity
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Explicit empty, isolated test installation only. Never redeems a real QR. */
@RunWith(AndroidJUnit4::class)
class QrSetupUiTest {
    @Test fun qrIncludesItsAddressEvenWhenSavedAccountsNeedReconnection(){
        val inst=InstrumentationRegistry.getInstrumentation();val context=inst.targetContext
        assumeTrue(InstrumentationRegistry.getArguments().getString("qrSetupIsolated")=="true")
        val store=PhoneStore(context);require(store.profiles().isEmpty() && PhoneService.instance==null){"Use an empty isolated app with no phone service"}
        val owned=mutableListOf<String>();var activity:Activity?=null
        try{
            for(index in 1..2){
                val profile=JSONObject().put("server","https://legacy-$index.example.invalid").put("device_id","owned-$index")
                    .put("token","owned-qr-fixture-token-$index").put("account",JSONObject().put("extension","100$index"))
                    .put("sip",JSONObject().put("domain","legacy-$index.example.invalid").put("username","owned-$index").put("password","owned-fixture-secret"))
                owned+=store.add(profile)
            }
            val before=store.profiles().associate{it.getString("profile_id") to it.toString()}
            val home=inst.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) as MainActivity
            activity=home
            val qr=JSONObject().put("type","openwebpbx").put("version",1).put("server","https://alpha.openwebpbx.com")
                .put("code","a".repeat(64)).put("extension","1000").toString()
            inst.runOnMainSync{MainActivity::class.java.getDeclaredMethod("confirmSetup",String::class.java).apply{isAccessible=true}.invoke(home,qr)}
            val device=UiDevice.getInstance(inst)
            assertTrue(device.wait(Until.hasObject(By.text("Add this phone account?")),5000))
            assertNotNull(device.findObject(By.textContains("alpha.openwebpbx.com · Extension 1000")))
            assertNotNull(device.findObject(By.text("Connect")))
            val dialog=requireNotNull(device.findObject(By.res("android","parentPanel")))
            assertEquals("QR confirmation must not require typing a host",0,dialog.findObjects(By.clazz("android.widget.EditText")).size)
            device.findObject(By.text("Cancel")).click()
            assertEquals(before,store.profiles().associate{it.getString("profile_id") to it.toString()})
            assertNull(PhoneService.instance)
        }finally{
            activity?.let{value->inst.runOnMainSync{value.finish()}}
            // Remove only this test's newly added profiles, never a shared reset.
            for(id in owned){val value=store.read(id);if(value!=null){check(value.getString("token").startsWith("owned-qr-fixture-token-"));store.remove(id)}}
        }
    }
}
