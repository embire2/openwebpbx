package com.openweb.pbx

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
import org.linphone.core.Call
import org.linphone.core.MediaEncryption
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

@RunWith(AndroidJUnit4::class)
class TenantOriginWorkflowTest {
    @Test fun actual116ReplacementRequiresEntryThenRetainsAccountAndCalling(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("tenantOriginFixture")=="true")
        val instrument=InstrumentationRegistry.getInstrumentation();val context=instrument.targetContext
        assertEquals("1.0.18",context.packageManager.getPackageInfo(context.packageName,0).versionName)
        val files=context.getExternalFilesDir(null)!!;val before=JSONObject(File(files,"tenant-origin-before.private.json").readText())
        val setup=JSONObject(File(files,"tenant-origin-setup.json").readText());val store=PhoneStore(context);val device=UiDevice.getInstance(instrument)
        fun main(block:()->Unit)=instrument.runOnMainSync(block)
        fun await(label:String,millis:Long=60000,predicate:()->Boolean){val end=System.currentTimeMillis()+millis;while(System.currentTimeMillis()<end){if(predicate())return;Thread.sleep(100)};fail(label)}
        main{context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}
        assertTrue(device.wait(Until.hasObject(By.text("Confirm tenant address")),15000))
        Thread.sleep(1500)
        val pending=store.read()!!;assertFalse(TenantConnection.ready(pending))
        main{assertTrue(PhoneService.instance?.core?.accountList?.isEmpty()!=false)}
        for(key in listOf("server","token","device_id","sip"))assertEquals(before.get(key).toString(),pending.get(key).toString())
        val prefs=JSONObject(File(files,"tenant-origin-preferences.private.json").readText())
        for(key in prefs.keys())assertEquals(prefs.get(key).toString(),context.getSharedPreferences("phone_preferences",0).all[key].toString())
        for(invalid in listOf("https://call.openweb.co.za","https://tenant.openwebpbx.com.evil.test")){
            device.findObject(By.clazz("android.widget.EditText")).text=invalid
            device.findObject(By.text("Confirm tenant address")).click();Thread.sleep(300)
            assertFalse(TenantConnection.ready(store.read()!!));assertEquals(before.getString("server"),store.read()!!.getString("server"))
        }
        device.findObject(By.clazz("android.widget.EditText")).text=setup.getString("tenant_server")
        device.findObject(By.text("Confirm tenant address")).click()
        await("Address confirmation did not finish"){TenantConnection.ready(store.read()!!)}
        await("Native TLS phone did not register"){PhoneService.instance?.status=="Ready for calls"}
        val after=store.read()!!
        for(key in listOf("token","device_id","sip"))assertEquals(before.get(key).toString(),after.get(key).toString())
        assertEquals(setup.getString("tenant_server"),after.getString("server"))
        val phone=PhoneService.instance!!;val count=8000*20
        val bytes=ByteBuffer.allocate(44+count*2).order(ByteOrder.LITTLE_ENDIAN)
        bytes.put("RIFF".toByteArray()).putInt(36+count*2).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16).put("data".toByteArray()).putInt(count*2)
        repeat(count){bytes.putShort((8000*kotlin.math.sin(2*Math.PI*440*it/8000)).toInt().toShort())}
        val tone=File(context.filesDir,"tenant118-owned-tone.wav").apply{writeBytes(bytes.array())}
        try{
            main{phone.core!!.useFiles=true;phone.core!!.playFile=tone.path;phone.core!!.recordFile=File(files,"tenant118-received.wav").path;phone.dial("8101")}
            await("Owned native call was not answered"){var running=false;main{running=phone.call?.state==Call.State.StreamsRunning};running}
            Thread.sleep(6000)
            main{assertEquals(MediaEncryption.SRTP,phone.call!!.currentParams.mediaEncryption);assertTrue(phone.call!!.audioStats!!.rtpPacketRecv>200);assertTrue(phone.call!!.audioStats!!.rtpPacketSent>200);phone.hangup()}
            await("Owned call did not end"){var ended=false;main{ended=phone.call==null};ended}
        }finally{main{phone.hangup();phone.core?.useFiles=false;phone.core?.playFile=null;phone.core?.recordFile=null};tone.delete()}
        File(files,"tenant-origin118.safe.json").writeText(JSONObject().put("exact116_to118",true).put("forced_address_entry",true).put("disallowed_origins_refused",true).put("no_pending_sdk_accounts",true).put("token_device_sip_exact",true).put("preferences_exact",true).put("native_srtp_call",true).toString())
    }
}
