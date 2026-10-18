/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
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
import org.linphone.core.RegistrationState
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Explicitly supplied, private two-tenant fixture only; no production defaults. */
@RunWith(AndroidJUnit4::class)
class ProfileWorkflowTest {
    private val inst get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=inst.targetContext
    private val files get()=context.getExternalFilesDir(null)!!
    private val store get()=PhoneStore(context)
    private val device get()=UiDevice.getInstance(inst)
    private fun main(block:()->Unit)=inst.runOnMainSync(block)
    private fun await(label:String,seconds:Int=60,test:()->Boolean){val until=System.currentTimeMillis()+seconds*1000;while(System.currentTimeMillis()<until){var ok=false;main{ok=test()};if(ok)return;Thread.sleep(250)};fail(label)}
    private fun phase(name:String){File(files,"profile-phase.json").writeText(JSONObject().put("phase",name).put("at",System.currentTimeMillis()).toString())}
    private fun views(view:View):List<View> = listOf(view)+if(view is ViewGroup)(0 until view.childCount).flatMap{views(view.getChildAt(it))}else emptyList()
    private fun click(activity:MainActivity,label:String){main{val v=views(activity.window.decorView).filterIsInstance<Button>().firstOrNull{it.text.toString()==label} ?: error("Missing action $label");v.performClick()};inst.waitForIdleSync()}
    private fun invoke(activity:MainActivity,name:String){main{MainActivity::class.java.getDeclaredMethod(name).apply{isAccessible=true}.invoke(activity)};inst.waitForIdleSync()}
    private fun dialogInputs():List<androidx.test.uiautomator.UiObject2>{assertTrue(device.wait(Until.hasObject(By.clazz(EditText::class.java)),8000));return device.findObjects(By.clazz(EditText::class.java))}
    private fun submit(label:String){device.findObject(By.res("android:id/button1")).click();Thread.sleep(250)}
    private fun tone():File {
        val count=8000*30;val bytes=ByteBuffer.allocate(44+count*2).order(ByteOrder.LITTLE_ENDIAN)
        bytes.put("RIFF".toByteArray()).putInt(36+count*2).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16).put("data".toByteArray()).putInt(count*2)
        repeat(count){bytes.putShort((8000*kotlin.math.sin(2*Math.PI*440*it/8000)).toInt().toShort())}
        return File(context.filesDir,"profile-tone.wav").apply{writeBytes(bytes.array())}
    }
    private fun media(phone:PhoneService,name:String){
        var received=0L;var sent=0L
        main{assertEquals(MediaEncryption.SRTP,phone.call!!.currentParams.mediaEncryption);received=phone.call!!.audioStats!!.rtpPacketRecv;sent=phone.call!!.audioStats!!.rtpPacketSent}
        Thread.sleep(8000)
        main{assertEquals(Call.State.StreamsRunning,phone.call!!.state);assertTrue("$name receive",phone.call!!.audioStats!!.rtpPacketRecv>received+200);assertTrue("$name send",phone.call!!.audioStats!!.rtpPacketSent>sent+200)}
    }
    @Test fun activeCallPasswordContinuityAndExplicitOfflineRemoval(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("offlineProfileFixture")=="true")
        val fixture=JSONObject(File(files,"profiles-fixture.json").readText());val tenants=fixture.getJSONObject("tenants");val a=tenants.getJSONObject("a");val b=tenants.getJSONObject("b")
        require(a.getString("host")=="qa-a-m117a8.openwebpbx.com" && b.getString("host")=="qa-b-m117a8.openwebpbx.com" && store.profiles().size==1)
        val original=store.read()!!;val aid=original.getString("profile_id");val apiA=PhoneApi(original.getString("server"),original.getString("token"))
        val other=ProfileRules.connected(PhoneApi("https://"+b.getString("host")).json("login",JSONObject().put("extension","100").put("password",b.getJSONObject("users").getJSONObject("100").getString("app_password")).put("device_name","Owned offline-removal QA").put("platform","android")),"https://"+b.getString("host"))
        val bid=store.add(other,false);val apiB=PhoneApi(other.getString("server"),other.getString("token"));val old=a.getJSONObject("users").getJSONObject("100").getString("app_password");val fresh="Owned-"+java.util.UUID.randomUUID();var changed=false
        val home=inst.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) as MainActivity
        val tone=tone()
        try{
            await("Both accounts registered before fault",120){PhoneService.instance?.core?.accountList?.count{it.state==RegistrationState.Ok}==2};val phone=PhoneService.instance!!
            main{phone.core!!.useFiles=true;phone.core!!.playFile=tone.path;phone.core!!.recordFile=File(files,"profile-password-active.wav").path;phone.dial("101")}
            await("Password continuity call answered"){phone.call?.state==Call.State.StreamsRunning};media(phone,"before password change")
            apiA.json("change_password",JSONObject().put("current_password",old).put("new_password",fresh));changed=true
            assertEquals(original.getString("token"),store.read(aid)!!.getString("token"));assertEquals(original.getJSONObject("sip").toString(),store.read(aid)!!.getJSONObject("sip").toString());assertEquals("100",apiA.json("bootstrap").getJSONObject("account").getString("extension"));media(phone,"after password change")
            apiA.json("change_password",JSONObject().put("current_password",fresh).put("new_password",old));changed=false
            main{try{MainActivity::class.java.getDeclaredMethod("removeProfile",String::class.java).apply{isAccessible=true}.invoke(home,bid);fail("Removal opened during a call")}catch(e:java.lang.reflect.InvocationTargetException){assertTrue(e.cause is IllegalStateException)}}
            invoke(home,"accounts");device.findObjects(By.clazz(Button::class.java)).first{it.text?.removePrefix("✓ ")==ProfileRules.label(store.read(bid)!!)}.click();assertEquals(aid,store.selectedId());device.findObject(By.res("android:id/button2")).click()
            var accepted=0;val action:(String,Boolean)->Unit={_,_->accepted++}
            main{MainActivity::class.java.getDeclaredMethod("destinationDialog",String::class.java,Boolean::class.javaPrimitiveType,kotlin.jvm.functions.Function2::class.java).apply{isAccessible=true}.invoke(home,"Transfer",true,action)}
            dialogInputs().single().text="101"
            main{assertEquals(Call.State.StreamsRunning,phone.call!!.state);phone.hangup()};await("First call ended before stale action"){phone.calls.isEmpty()}
            main{store.select(bid);phone.syncProfiles();phone.core!!.recordFile=File(files,"profile-stale-dialog-b.wav").path;phone.dial("101")}
            await("Other tenant call answered"){phone.call?.state==Call.State.StreamsRunning};submit("Continue")
            main{assertEquals("Old transfer dialog must not act on another tenant's call",0,accepted);assertEquals(bid,phone.profileId());assertEquals(Call.State.StreamsRunning,phone.call!!.state)}
            device.findObject(By.res("android:id/button2")).click();media(phone,"other tenant protected from stale transfer")
            main{phone.hangup()};await("Call ended before account removal"){phone.calls.isEmpty()};main{store.select(aid);phone.syncProfiles()}
            store.update(bid){it.put("server","https://offline-m117a8.example.invalid")}
            await("API-origin fault retains both native registrations",30){phone.core!!.accountList.count{it.state==RegistrationState.Ok}==2}
            fun removeDialog(){main{MainActivity::class.java.getDeclaredMethod("removeProfile",String::class.java).apply{isAccessible=true}.invoke(home,bid)};assertTrue(device.wait(Until.hasObject(By.text("Remove this phone account?")),5000));submit("Remove");assertTrue(device.wait(Until.hasObject(By.text("Could not reach this account's server")),30000))}
            removeDialog();assertEquals(2,store.profiles().size);device.findObject(By.res("android:id/button2")).click();assertNotNull(store.read(bid))
            removeDialog();assertEquals(2,store.profiles().size);submit("Remove from this phone anyway")
            await("Explicit offline local removal"){store.read(bid)==null && store.profiles().size==1};await("Other account remains ready"){phone.core!!.accountList.size==1 && phone.profileStatus(aid)=="Ready for calls"}
            assertEquals(original.getString("token"),store.read(aid)!!.getString("token"));assertEquals(original.getJSONObject("sip").toString(),store.read(aid)!!.getJSONObject("sip").toString())
            assertEquals("100",apiB.json("bootstrap").getJSONObject("account").getString("extension")) // UI truthfully did not claim remote revocation.
            phase("active_password_offline_removal_complete")
        }finally{
            if(changed)apiA.json("change_password",JSONObject().put("current_password",fresh).put("new_password",old))
            try{apiB.json("revoke",JSONObject())}catch(_:Exception){}
            main{PhoneService.instance?.let{it.hangup();it.core?.useFiles=false;it.core?.playFile=null;it.core?.recordFile=null};home.finish()};tone.delete()
        }
    }
    @Test fun freshQrPasswordInitializationEditRemoveAndNotificationIsolation(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("firstPasswordFixture")=="true")
        val setup=JSONObject(File(files,"first-password-fixture.json").readText());require(setup.getString("server")=="https://qa-a-m117a8.openwebpbx.com" && setup.getString("extension")=="102")
        require(store.profiles().size==1);val original=store.read()!!;val originalId=original.getString("profile_id")
        val home=inst.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) as MainActivity
        val uri=Uri.parse("content://com.openweb.pbx.test.setup-fixture/owned")
        try{
            context.contentResolver.insert(uri,ContentValues().apply{put("payload",setup.toString())})
            main{home.startActivity(Intent(Intent.ACTION_VIEW).setClass(context,MainActivity::class.java).setDataAndType(uri,"application/vnd.openwebpbx.config+json").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}
            assertTrue(device.wait(Until.hasObject(By.text("Add this phone account?")),10000));submit("Connect")
            await("Fresh QR setup persisted"){store.profiles().size==2};val id=store.profiles().single{it.getString("profile_id")!=originalId}.getString("profile_id")
            await("Fresh QR account registered",120){PhoneService.instance?.profileStatus(id)=="Ready for calls" && store.selectedId()==id}
            val saved=store.read(id)!!;assertFalse(saved.getJSONObject("account").getBoolean("app_password_set"));assertTrue(saved.getJSONObject("account").getBoolean("can_initialize_app_password"))
            main{MainActivity::class.java.getDeclaredMethod("editProfile",String::class.java).apply{isAccessible=true}.invoke(home,id)}
            val fields=dialogInputs();assertEquals(1,fields.size);fields[0].text="My second phone account";submit("Save")
            await("Edited name retained"){store.read(id)?.optString("profile_name")=="My second phone account"}
            invoke(home,"changeAppPassword");assertTrue(device.wait(Until.hasObject(By.text("Create app password")),5000));val pwd=dialogInputs();assertEquals("First setup must not require a nonexistent current password",2,pwd.size)
            val password="Owned-"+java.util.UUID.randomUUID();pwd[0].text=password;pwd[1].text=password;submit("Change password")
            await("Password initialization saved"){store.read(id)?.getJSONObject("account")?.optBoolean("app_password_set")==true}
            val api=PhoneApi(saved.getString("server"),saved.getString("token"));val bootstrap=api.json("bootstrap");assertTrue(bootstrap.getJSONObject("account").getBoolean("app_password_set"));assertEquals(saved.getString("token"),store.read(id)!!.getString("token"));assertEquals(saved.getJSONObject("sip").toString(),store.read(id)!!.getJSONObject("sip").toString());assertFalse(store.read(id)!!.toString().contains(password))
            // Two identical request IDs remain separate by profile. This checks
            // native notification routing, not physical FCM/locked-device delivery.
            val request=java.util.UUID.randomUUID().toString();val manager=context.getSystemService(android.app.NotificationManager::class.java)
            main{PushConnection.notify(context,request,java.time.Instant.now().epochSecond+30,originalId);PushConnection.notify(context,request,java.time.Instant.now().epochSecond+30,id)}
            await("Both tenant notifications retained",10){manager.activeNotifications.count{it.id==12 && it.tag?.endsWith(request)==true}==2}
            main{PushConnection.cancel(context,request,originalId)}
            await("Cancelling one tenant leaves the other notification",10){manager.activeNotifications.none{it.tag=="push:$originalId:$request"} && manager.activeNotifications.any{it.tag=="push:$id:$request"}}
            main{PushConnection.cancel(context,request,id)}
            main{MainActivity::class.java.getDeclaredMethod("removeProfile",String::class.java).apply{isAccessible=true}.invoke(home,id)}
            assertTrue(device.wait(Until.hasObject(By.text("Remove this phone account?")),5000));submit("Remove")
            await("Native remove action completed"){store.profiles().size==1 && store.selectedId()==originalId}
            await("Original account remains registered",60){PhoneService.instance?.core?.accountList?.size==1 && PhoneService.instance?.profileStatus(originalId)=="Ready for calls"}
            assertEquals(original.getString("token"),store.read()!!.getString("token"));assertEquals(original.getJSONObject("sip").toString(),store.read()!!.getJSONObject("sip").toString())
            try{api.json("bootstrap");fail("Removed device remained authorized")}catch(e:ApiError){assertEquals(401,e.status)}
            phase("first_password_edit_remove_notifications_complete")
        }finally{context.contentResolver.delete(uri,null,null);main{home.finish()}}
    }
    @Test fun twoTenantsLoginImportIncomingOutgoingPasswordAndRemoval(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("profilesFixture")=="true")
        val fixture=JSONObject(File(files,"profiles-fixture.json").readText());val tenants=fixture.getJSONObject("tenants");val a=tenants.getJSONObject("a");val b=tenants.getJSONObject("b")
        require(listOf(a,b).all{it.getString("host").matches(Regex("qa-[ab]-m117a8\\.openwebpbx\\.com"))})
        require(store.profiles().size<=1 && store.profiles().all{it.getString("server")=="https://"+a.getString("host")}){"Use only the explicitly owned first test account"}
        device.wakeUp();device.pressMenu()
        for(permission in listOf("RECORD_AUDIO","POST_NOTIFICATIONS","BLUETOOTH_CONNECT"))inst.uiAutomation.executeShellCommand("pm grant ${context.packageName} android.permission.$permission").close()
        var home=inst.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) as MainActivity
        var phone:PhoneService?=null;var tone:File?=null
        try{
            if(store.profiles().isEmpty()){
            click(home,"Sign in with an app password")
            val inputs=dialogInputs();assertEquals(3,inputs.size);inputs[0].text=a.getString("host").removeSuffix(".openwebpbx.com");inputs[1].text="100";inputs[2].text=a.getJSONObject("users").getJSONObject("100").getString("app_password");submit("Sign in")
            await("Manual app-password login saved"){store.profiles().size==1}
            }
            val aid=store.selectedId()!!
            await("First native TLS registration",120){PhoneService.instance?.profileStatus(aid)=="Ready for calls"}
            phase("manual_login_registered")
            val uri=Uri.parse("content://com.openweb.pbx.test.setup-fixture/owned")
            context.contentResolver.insert(uri,ContentValues().apply{put("payload",b.getJSONObject("qr").toString())})
            main{home.startActivity(Intent(Intent.ACTION_VIEW).setClass(context,MainActivity::class.java).setDataAndType(uri,"application/vnd.openwebpbx.config+json").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}
            assertTrue(device.wait(Until.hasObject(By.text("Add this phone account?")),10000));assertEquals(1,store.profiles().size);submit("Connect")
            await("Setup-file account saved"){store.profiles().size==2}
            val bid=store.profiles().single{it.getString("profile_id")!=aid}.getString("profile_id")
            await("Both native TLS registrations",120){PhoneService.instance?.core?.accountList?.count{it.state==RegistrationState.Ok}==2}
            phone=PhoneService.instance!!;val phone=phone!!
            invoke(home,"accounts");assertTrue(device.wait(Until.hasObject(By.textContains(ProfileRules.label(store.read(aid)!!))),5000));device.findObjects(By.clazz(Button::class.java)).first{it.text?.removePrefix("✓ ")==ProfileRules.label(store.read(aid)!!)}.click()
            await("Outgoing account selection"){store.selectedId()==aid && phone.core!!.defaultAccount!!.params.idkey==aid}
            val mediaTone=tone();tone=mediaTone;main{phone.core!!.useFiles=true;phone.core!!.playFile=mediaTone.path;phone.core!!.recordFile=File(files,"profile-b-incoming.wav").path}
            phase("incoming_b")
            await("Incoming second tenant while first selected",90){phone.waitingCall!=null || phone.call?.state==Call.State.IncomingReceived}
            main{assertEquals(bid,phone.profileId(phone.waitingCall ?: phone.call));assertEquals(aid,store.selectedId());phone.answer()}
            await("Second tenant answered"){phone.call?.state==Call.State.StreamsRunning};media(phone,"incoming B")
            main{try{phone.beginProfileChange(aid);fail("Active call allowed account change")}catch(_:IllegalStateException){};assertEquals(aid,store.selectedId());phone.hangup()}
            await("Incoming ended"){phone.calls.isEmpty()};phone.flushPending();Thread.sleep(1800)
            main{phone.core!!.recordFile=File(files,"profile-a-outgoing.wav").path;phone.dial("101")}
            await("Selected tenant outgoing answered"){phone.call?.state==Call.State.StreamsRunning};main{assertEquals(aid,phone.profileId())};media(phone,"outgoing A")
            main{phone.hold()};await("Hold selected tenant"){phone.call?.state==Call.State.Paused};main{phone.hold()};await("Resume selected tenant"){phone.call?.state==Call.State.StreamsRunning};media(phone,"resumed A");main{phone.hangup()};await("Outgoing ended"){phone.calls.isEmpty()};phone.flushPending();Thread.sleep(2200)
            val pa=store.read(aid)!!;val pb=store.read(bid)!!;val apiA=PhoneApi(pa.getString("server"),pa.getString("token"));val apiB=PhoneApi(pb.getString("server"),pb.getString("token"))
            fun directions(api:PhoneApi)=api.json("calls").getJSONArray("calls").let{rows->(0 until rows.length()).map{rows.getJSONObject(it).getString("direction")}}
            assertTrue("A history contains its outgoing call",directions(apiA).contains("outgoing"));assertFalse("A history contains B incoming",directions(apiA).contains("incoming"));assertTrue("B history contains incoming",directions(apiB).contains("incoming"));assertFalse("B history contains A outgoing",directions(apiB).contains("outgoing"))
            phase("two_tenant_media_and_history_passed")
            val old=a.getJSONObject("users").getJSONObject("100").getString("app_password");val fresh="Owned-"+java.util.UUID.randomUUID().toString();val before=pa.getJSONObject("sip").toString();val token=pa.getString("token")
            try{apiA.json("change_password",JSONObject().put("current_password","wrong-owned-password").put("new_password",fresh));fail("Wrong current password accepted")}catch(e:ApiError){assertEquals(401,e.status)}
            assertFalse(store.read(aid)!!.optBoolean("needs_login"));assertEquals("100",apiA.json("bootstrap").getJSONObject("account").getString("extension"))
            invoke(home,"changeAppPassword");val pwd=dialogInputs();assertEquals(3,pwd.size);pwd[0].text=old;pwd[1].text=fresh;pwd[2].text=fresh;submit("Change password")
            Thread.sleep(2000);assertEquals(token,store.read(aid)!!.getString("token"));assertEquals(before,store.read(aid)!!.getJSONObject("sip").toString());assertEquals("100",apiA.json("bootstrap").getJSONObject("account").getString("extension"))
            val spare=PhoneApi(pa.getString("server")).json("login",JSONObject().put("extension","100").put("password",fresh).put("device_name","Owned password verification").put("platform","android"));PhoneApi(pa.getString("server"),spare.getString("token")).json("revoke",JSONObject())
            apiA.json("change_password",JSONObject().put("current_password",fresh).put("new_password",old))
            main{assertEquals(2,phone.core!!.accountList.count{it.state==RegistrationState.Ok});phone.beginProfileChange(bid)}
            apiB.json("revoke",JSONObject());PushConnection.unregister(context,bid);store.remove(bid);main{phone.endProfileChange(bid)}
            await("Removing B preserves A connection"){phone.core!!.accountList.size==1 && phone.profileStatus(aid)=="Ready for calls"};assertEquals(token,store.read(aid)!!.getString("token"));assertEquals(aid,store.selectedId())
            phase("complete")
        }finally{context.contentResolver.delete(Uri.parse("content://com.openweb.pbx.test.setup-fixture/owned"),null,null);main{phone?.calls?.toList()?.forEach{phone?.hangup(it)};phone?.core?.useFiles=false;phone?.core?.playFile=null;phone?.core?.recordFile=null;home.finish()};tone?.delete()}
    }
}
