/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.app.Activity
import android.content.Intent
import android.graphics.BitmapFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.google.zxing.BinaryBitmap
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.linphone.core.RegistrationState
import java.io.File

/** Operator-supplied fresh fictional tenants only. No TLS/custodian/SIP bypass. */
@RunWith(AndroidJUnit4::class)
class QrProvisioningWorkflowTest {
    @Test fun realQrEnrollmentAndReconnectKeepTheOtherTenantRegistered(){
        val inst=InstrumentationRegistry.getInstrumentation();val context=inst.targetContext
        require(InstrumentationRegistry.getArguments().getString("qrEnrollmentFixture")=="true")
        val files=requireNotNull(context.getExternalFilesDir(null))
        val fixture=JSONObject(File(files,"qr120-fixture.private.json").readText())
        val nonce=fixture.getString("owner_nonce");require(nonce.matches(Regex("[a-f0-9]{12}")))
        require(fixture.getInt("schema")==1 && fixture.getString("scope")=="new-owned-qr120-tenants-only")
        val a=fixture.getJSONObject("a");val b=fixture.getJSONObject("b")
        for((name,tenant) in listOf("a" to a,"b" to b)){
            require(tenant.getString("server")=="https://qa-qr120-$nonce-$name.openwebpbx.com")
            val sipNonce=tenant.getString("sip_nonce");require(sipNonce.matches(Regex("[a-f0-9]{12}")))
            require(tenant.getString("sip_domain")=="mobile-check-$sipNonce.invalid")
            require(tenant.getString("extension")=="1000")
            for(key in listOf("domain_uuid","extension_uuid"))require(tenant.getString(key).matches(Regex("[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}")))
        }
        require(a.getString("domain_uuid")!=b.getString("domain_uuid") && a.getString("sip_nonce")!=b.getString("sip_nonce"))
        val store=PhoneStore(context);require(store.profiles().isEmpty() && PhoneService.instance==null)
        val owned=mutableSetOf<String>();var activity:MainActivity?=null
        val device=UiDevice.getInstance(inst)
        fun ui(action:()->Unit){inst.runOnMainSync{action()};inst.waitForIdleSync()}
        fun waitFor(label:String,timeout:Long=120000,condition:()->Boolean){val start=System.currentTimeMillis();while(!condition()){check(System.currentTimeMillis()-start<timeout){label};Thread.sleep(100)}}
        fun profile(tenant:JSONObject)=store.profiles().single{it.getJSONObject("account").optString("domain_uuid")==tenant.getString("domain_uuid")}
        fun decode(name:String,tenant:JSONObject):String{
            require(name.matches(Regex("qr120-(?:a|b|a-reconnect)\\.png")))
            val image=requireNotNull(BitmapFactory.decodeFile(File(files,name).path));require(image.width<=2048&&image.height<=2048)
            val pixels=IntArray(image.width*image.height);image.getPixels(pixels,0,image.width,0,0,image.width,image.height)
            val raw=MultiFormatReader().decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(image.width,image.height,pixels)))).text;image.recycle()
            val qr=ProfileRules.setup(raw);require(qr.getString("server")==tenant.getString("server")&&qr.getString("extension")==tenant.getString("extension"));return raw
        }
        fun scan(raw:String){
            val home=requireNotNull(activity)
            ui{MainActivity::class.java.getDeclaredMethod("confirmSetup",String::class.java).apply{isAccessible=true}.invoke(home,raw)}
            assertTrue(device.wait(Until.hasObject(By.text("Add this phone account?")),10000))
            val dialog=requireNotNull(device.findObject(By.res("android","parentPanel")))
            assertEquals("QR must not request manual address or password",0,dialog.findObjects(By.clazz("android.widget.EditText")).size)
            device.findObject(By.text("Connect")).click()
        }
        fun bAccount()=requireNotNull(PhoneService.instance?.core).accountList.single{it.params.idkey==profile(b).getString("profile_id")}
        try{
            activity=inst.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))as MainActivity
            scan(decode("qr120-a.png",a));waitFor("First QR did not create its exact tenant account"){store.profiles().size==1};owned+=profile(a).getString("profile_id")
            waitFor("First QR TLS registration did not become ready"){PhoneService.instance?.profileStatus(owned.single())=="Ready for calls"}
            scan(decode("qr120-b.png",b));waitFor("Second QR did not create a separate tenant account"){store.profiles().size==2};owned+=profile(b).getString("profile_id")
            waitFor("Both QR accounts did not register"){PhoneService.instance?.core?.accountList?.count{it.state==RegistrationState.Ok}==2}
            val aid=profile(a).getString("profile_id");val bid=profile(b).getString("profile_id");assertNotEquals(aid,bid)
            val beforeB=JSONObject(profile(b).toString());var bPointer=0L
            ui{bPointer=bAccount().nativePointer;assertTrue(requireNotNull(bAccount().params.natPolicy).isStunEnabled)}
            for(tenant in listOf(a,b)){
                val connected=profile(tenant);assertTrue(TenantConnection.ready(connected));assertEquals(tenant.getString("server"),connected.getString("server"));assertEquals(tenant.getString("extension_uuid"),connected.getJSONObject("account").getString("extension_uuid"));assertEquals(tenant.getString("sip_domain"),connected.getJSONObject("sip").getString("domain"))
            }
            // An owned legacy marker exercises the real QR reconnect path while B stays live.
            ui{store.update(aid){it.put("needs_login",true).put("profile_name","Owned QR120 account A");it.remove("tenant_url_policy");it.remove("tenant_url_confirmed")};store.select(aid);PhoneService.instance!!.syncProfiles()}
            waitFor("Other tenant registration was disrupted before reconnect"){bAccount().state==RegistrationState.Ok}
            scan(decode("qr120-a-reconnect.png",a));waitFor("Re-enrollment did not reuse the original local profile"){store.read(aid)?.let{TenantConnection.ready(it)}==true}
            waitFor("Both tenant registrations did not recover"){PhoneService.instance?.core?.accountList?.count{it.state==RegistrationState.Ok}==2}
            assertEquals(2,store.profiles().size);assertEquals(aid,profile(a).getString("profile_id"));assertEquals("Owned QR120 account A",profile(a).getString("profile_name"))
            val afterB=profile(b);for(key in listOf("profile_id","device_id","token","sip"))assertEquals("Reconnecting A changed B's identity",beforeB.get(key).toString(),afterB.get(key).toString())
            ui{assertEquals("Reconnecting A rebuilt B's live SDK account",bPointer,bAccount().nativePointer);assertEquals(RegistrationState.Ok,bAccount().state);assertTrue(PhoneService.instance!!.calls.isEmpty())}
            File(files,"qr120-native-workflow.safe.json").writeText(JSONObject().put("schema",1).put("owner_nonce",nonce).put("actual_QR_PNG_decode",true).put("actual_custodian_HTTPS_and_enrollment",true).put("no_manual_address",true).put("two_tenant_TLS_registrations",true).put("same_local_profile_on_reenrollment",true).put("other_tenant_SDK_pointer_unchanged",true).put("calling_or_physical_camera_qualified",false).toString())
        }finally{
            activity?.let{home->ui{home.finish()}}
            for(id in owned){val saved=store.read(id);if(saved!=null){check(saved.getJSONObject("account").getString("domain_uuid")in listOf(a.getString("domain_uuid"),b.getString("domain_uuid")));store.remove(id)}}
            if(store.profiles().isEmpty())context.stopService(Intent(context,PhoneService::class.java))
        }
    }
}
