/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith
import org.linphone.core.Call
import java.io.File

/** Requires three disposable local extensions. Never run against customer endpoints. */
@RunWith(AndroidJUnit4::class)
class AdvancedCallingTest {
    private val instrument get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrument.targetContext
    private val files get()=context.getExternalFilesDir(null)!!
    private fun main(block:()->Unit)=instrument.runOnMainSync(block)
    private fun waitFor(label:String,seconds:Int=45,test:()->Boolean){val end=System.currentTimeMillis()+seconds*1000;while(System.currentTimeMillis()<end){var ready=false;main{ready=test()};if(ready)return;Thread.sleep(250)};fail(label)}
    private fun connect(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("advancedFixture")=="true")
        UiDevice.getInstance(instrument).apply{wakeUp();pressMenu()}
        if(PhoneStore(context).read()==null){val setup=JSONObject(File(files,"audio-setup.json").readText());val server=setup.getString("server");val a=PhoneApi(server).json("enroll",JSONObject().put("code",setup.getString("code")).put("device_name","Advanced calling QA")).put("server",server);PhoneStore(context).save(a);File(files,"audio-setup.json").delete()}
        main{context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))};waitFor("Registration unavailable",90){PhoneService.instance?.status=="Ready for calls"}
    }
    private fun first(){connect();main{PhoneService.instance!!.dial("1001")};waitFor("First person did not answer"){PhoneService.instance?.call?.state==Call.State.StreamsRunning};Thread.sleep(3500)}
    @After fun end(){
        if(InstrumentationRegistry.getArguments().getString("advancedFixture")!="true")return
        val realm=PhoneStore(context).read()?.optJSONObject("sip")?.optString("domain") ?: return
        if(!realm.matches(Regex("mobile-check-[a-f0-9]{12}\\.invalid")))return
        main{PhoneService.instance?.calls?.toList()?.forEach{PhoneService.instance?.hangup(it)}};Thread.sleep(1500)
    }
    @Test fun switchMergeAndRemove(){
        first();var original:Call?=null;main{original=PhoneService.instance!!.call;PhoneService.instance!!.dial("1002",true)}
        waitFor("Second person did not answer"){PhoneService.instance?.calls?.size==2&&PhoneService.instance?.call?.state==Call.State.StreamsRunning}
        main{assertEquals(Call.State.Paused,original!!.state);PhoneService.instance!!.switchCall(original!!)}
        waitFor("Switch did not return original audio"){PhoneService.instance?.call?.nativePointer==original!!.nativePointer&&original!!.state==Call.State.StreamsRunning}
        main{PhoneService.instance!!.merge()}
        waitFor("Conference did not contain two remote people"){PhoneService.instance?.conference?.participantCount==2}
        Thread.sleep(10000)
        main{val p=PhoneService.instance!!;assertEquals(2,p.calls.size);for(c in p.calls){assertTrue("Conference incoming media missing",c.audioStats!!.downloadBandwidth>0);assertTrue("Conference outgoing media missing",c.audioStats!!.uploadBandwidth>0)};p.muteParticipant(p.calls.last());assertTrue(p.calls.last().speakerMuted);p.muteParticipant(p.calls.last());p.hangup(p.calls.first{it.nativePointer!=original!!.nativePointer})}
        waitFor("Removing one person ended the original call"){PhoneService.instance?.calls?.size==1&&PhoneService.instance?.call?.nativePointer==original!!.nativePointer}
        Thread.sleep(5000);main{assertTrue("Remaining call lost incoming media",original!!.audioStats!!.downloadBandwidth>0);assertTrue("Remaining call lost outgoing media",original!!.audioStats!!.uploadBandwidth>0)}
        File(files,"three-way-verified.txt").writeText("Actual two remote endpoints, hold/switch, conference media and one-participant removal passed.\n")
    }
    @Test fun consultCancelReturnsOriginal(){
        first();var original:Call?=null;main{original=PhoneService.instance!!.call;PhoneService.instance!!.consult("1002")}
        waitFor("Consultation did not connect"){PhoneService.instance?.calls?.size==2&&PhoneService.instance?.call?.state==Call.State.StreamsRunning}
        main{PhoneService.instance!!.cancelConsultation()}
        waitFor("Cancellation did not restore original call"){PhoneService.instance?.calls?.size==1&&PhoneService.instance?.call?.nativePointer==original!!.nativePointer&&original!!.state==Call.State.StreamsRunning}
        Thread.sleep(5000);main{assertTrue(original!!.audioStats!!.downloadBandwidth>0);assertTrue(original!!.audioStats!!.uploadBandwidth>0)}
    }
    @Test fun unavailableConsultationReturnsOriginal(){
        first();var original:Call?=null;main{original=PhoneService.instance!!.call;PhoneService.instance!!.consult("1999")}
        waitFor("Failed consultation did not restore original"){PhoneService.instance?.calls?.size==1&&PhoneService.instance?.call?.nativePointer==original!!.nativePointer&&original!!.state==Call.State.StreamsRunning}
        Thread.sleep(4000);main{assertTrue(original!!.audioStats!!.downloadBandwidth>0)}
    }
    @Test fun attendedTransfer(){
        first();main{PhoneService.instance!!.consult("1002")}
        waitFor("Transfer consultation did not connect"){PhoneService.instance?.calls?.size==2&&PhoneService.instance?.call?.state==Call.State.StreamsRunning}
        File(files,"transfer-ready.txt").writeText("ready")
        main{PhoneService.instance!!.completeTransfer()}
        waitFor("Attended transfer did not release both local calls"){PhoneService.instance?.calls?.isEmpty()==true}
        File(files,"transfer-finished.txt").writeText("ready")
    }
    @Test fun blindTransfer(){
        first();main{PhoneService.instance!!.blindTransfer("1002")}
        waitFor("Blind transfer did not release local call"){PhoneService.instance?.calls?.isEmpty()==true}
        File(files,"blind-transfer-finished.txt").writeText("ready")
    }
    @Test fun callWaiting(){
        first();File(files,"waiting-ready.txt").writeText("ready")
        waitFor("Second incoming call not received",90){PhoneService.instance?.waitingCall!=null&&PhoneService.instance?.calls?.size==2}
        var first:Call?=null;main{first=PhoneService.instance!!.call;PhoneService.instance!!.answer()}
        waitFor("Waiting call did not answer"){PhoneService.instance?.call?.state==Call.State.StreamsRunning&&PhoneService.instance?.call?.nativePointer!=first!!.nativePointer}
        main{assertEquals(Call.State.Paused,first!!.state)};Thread.sleep(5000)
        main{PhoneService.instance!!.hangup()}
        waitFor("Ending second call lost original conversation"){PhoneService.instance?.calls?.size==1&&PhoneService.instance?.call?.nativePointer==first!!.nativePointer&&first!!.state==Call.State.StreamsRunning}
    }
    @Test fun networkRecovery(){
        first();val tokenBefore=java.security.MessageDigest.getInstance("SHA-256").digest(PhoneStore(context).read()!!.getString("token").toByteArray())
        File(files,"network-ready.txt").writeText("ready")
        waitFor("Network loss was not shown",60){PhoneService.instance?.status=="No network connection"}
        File(files,"network-lost.txt").writeText("ready")
        waitFor("Phone did not automatically reconnect",90){PhoneService.instance?.status=="Ready for calls"}
        val tokenAfter=java.security.MessageDigest.getInstance("SHA-256").digest(PhoneStore(context).read()!!.getString("token").toByteArray());assertTrue("Network recovery changed phone enrollment",tokenBefore.contentEquals(tokenAfter))
        Thread.sleep(8000)
        main{val phone=PhoneService.instance!!;if(phone.call!=null){assertEquals(Call.State.StreamsRunning,phone.call!!.state);assertTrue("Recovered call has no incoming media",phone.call!!.audioStats!!.downloadBandwidth>0);assertTrue("Recovered call has no outgoing media",phone.call!!.audioStats!!.uploadBandwidth>0)}else assertTrue("Interrupted call ended without useful explanation",phone.lastCallMessage.contains("connection",true))}
        main{PhoneService.instance?.hangup()};waitFor("Recovered phone did not release call"){PhoneService.instance?.calls?.isEmpty()==true}
        main{PhoneService.instance!!.dial("1001")};waitFor("New call after recovery failed"){PhoneService.instance?.call?.state==Call.State.StreamsRunning};Thread.sleep(5000)
        main{assertTrue(PhoneService.instance!!.call!!.audioStats!!.downloadBandwidth>0);assertTrue(PhoneService.instance!!.call!!.audioStats!!.uploadBandwidth>0)}
        File(files,"network-verified.txt").writeText("Actual Android network loss/reconnect retained account, recovered media or reported bounded failure, and next call passed.\n")
    }
    @Test fun holdMusic(){
        first();main{PhoneService.instance!!.hold()}
        waitFor("Hold did not complete"){PhoneService.instance?.call?.state==Call.State.Paused}
        File(files,"music-held.txt").writeText("ready")
        Thread.sleep(15000)
        main{PhoneService.instance!!.hold()}
        waitFor("Call did not resume after music"){PhoneService.instance?.call?.state==Call.State.StreamsRunning}
        Thread.sleep(3500);main{assertTrue(PhoneService.instance!!.call!!.audioStats!!.downloadBandwidth>0);assertTrue(PhoneService.instance!!.call!!.audioStats!!.uploadBandwidth>0)}
    }
    @Test fun availabilityAndQueues(){
        connect();val a=PhoneStore(context).read()!!;val api=PhoneApi.profile(a);val before=api.json("availability");val device=UiDevice.getInstance(instrument)
        try{
            val status=api.json("set_status",JSONObject().put("status","Do Not Disturb").put("minutes",15));assertEquals("Do Not Disturb",status.getString("status"));assertFalse(status.isNull("temporary_until"))
            val contacts=api.json("directory").getJSONArray("contacts");assertEquals("Do Not Disturb",(0 until contacts.length()).map{contacts.getJSONObject(it)}.single{it.getString("id")=="extension:1000"}.getString("status"))
            val joined=api.json("queue_status",JSONObject().put("number","600").put("joined",true)).getJSONArray("queues");val queue=(0 until joined.length()).map{joined.getJSONObject(it)}.single{it.getString("number")=="600"};assertTrue(queue.getBoolean("joined"));assertFalse(queue.getBoolean("receiving"));assertEquals("Paused by your status",queue.getString("receiving_reason"))
            assertTrue(device.wait(Until.hasObject(By.text("Status")),12000));device.findObject(By.text("Status")).click();assertTrue(device.wait(Until.hasObject(By.text("Status and queues")),12000));assertTrue(device.wait(Until.hasObject(By.text("Status: Do Not Disturb")),12000));assertNotNull(device.findObject(By.text("Native QA queue · Paused by your status")))
            device.findObject(By.res("android:id/button2")).click()
            api.json("set_status",JSONObject().put("status","Available").put("minutes",0))
            device.findObject(By.text("Status")).click();assertTrue(device.wait(Until.hasObject(By.text("Native QA queue · Receiving calls")),12000))
            device.findObject(By.text("Native QA queue · Receiving calls")).click();assertTrue(device.wait(Until.hasObject(By.text("Native QA queue · You left this queue")),12000));val current=api.json("availability").getJSONArray("queues");assertFalse((0 until current.length()).map{current.getJSONObject(it)}.single{it.getString("number")=="600"}.getBoolean("joined"))
            device.findObject(By.res("android:id/button2")).click()
            File(files,"availability-verified.txt").writeText("Actual authenticated DND, temporary duration, effective queue pause, native status dialog and per-queue leave passed.\n")
        }finally{
            api.json("set_status",JSONObject().put("status",before.getString("status")).put("minutes",0));val queues=before.getJSONArray("queues");for(i in 0 until queues.length()){val q=queues.getJSONObject(i);api.json("queue_status",JSONObject().put("number",q.getString("number")).put("joined",q.getBoolean("joined")))}
        }
    }
    @Test fun staleIncomingActionsPreserveConversation(){
        first();var original:Call?=null;main{original=PhoneService.instance!!.call}
        val device=UiDevice.getInstance(instrument)
        for(extra in listOf("call_id","push_request")){
            main{context.startActivity(Intent(context,IncomingCallActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra(extra,"00000000-0000-0000-0000-000000000001").putExtra("answer",true))}
            assertTrue("Stale notification did not close",device.wait(Until.hasObject(By.text("Status")),12000))
            main{assertEquals(original!!.nativePointer,PhoneService.instance!!.call!!.nativePointer);assertEquals(Call.State.StreamsRunning,original!!.state)}
        }
        Thread.sleep(4000);main{assertTrue(original!!.audioStats!!.downloadBandwidth>0);assertTrue(original!!.audioStats!!.uploadBandwidth>0)}
    }
    @Test fun releaseStoreScreenshots(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("storeScreenshots")=="true")
        connect()
        val saved=PhoneStore(context).read()!!
        require(saved.getJSONObject("sip").getString("domain").matches(Regex("mobile-check-[a-f0-9]{12}\\.invalid"))){"Disposable screenshot PBX required"}
        var resumed:MainActivity?=null
        waitFor("Screenshot screen did not resume"){
            resumed=ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).firstOrNull{it is MainActivity} as? MainActivity
            resumed!=null
        }
        val activity=resumed!!
        val output=File(files,"release-assets").apply{mkdirs()}
        fun capture(name:String){
            lateinit var bitmap:Bitmap
            main{
                assertTrue("Production capture protection stays enabled",activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE!=0)
                val panel=MainActivity::class.java.getDeclaredField("updatePanel").apply{isAccessible=true}.get(activity) as ViewGroup
                if(panel.childCount==0)panel.visibility=View.GONE
                val view=activity.window.decorView
                view.measure(View.MeasureSpec.makeMeasureSpec(view.width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(view.height,View.MeasureSpec.EXACTLY))
                view.layout(0,0,view.width,view.height)
                bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
                view.draw(Canvas(bitmap))
            }
            File(output,name).outputStream().use{assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))};bitmap.recycle()
        }
        val device=UiDevice.getInstance(instrument)
        try{
            Thread.sleep(1200);capture("01-keypad.png")
            device.findObject(By.desc("Contacts")).click()
            assertTrue(device.wait(Until.hasObject(By.textContains("1001")),12000));Thread.sleep(600);capture("04-contacts.png")
            device.findObject(By.desc("Voicemail")).click();Thread.sleep(1200);capture("03-voicemail.png")
            device.findObject(By.desc("Keypad")).click()
            main{PhoneService.instance!!.dial("1001")}
            waitFor("Screenshot call did not answer"){PhoneService.instance?.call?.state==Call.State.StreamsRunning}
            Thread.sleep(4000);main{assertTrue(PhoneService.instance!!.call!!.audioStats!!.downloadBandwidth>0);assertTrue(PhoneService.instance!!.call!!.audioStats!!.uploadBandwidth>0)};capture("02-call.png")
            main{PhoneService.instance!!.dial("1002",true)}
            waitFor("Screenshot second person did not answer"){PhoneService.instance?.calls?.size==2&&PhoneService.instance?.call?.state==Call.State.StreamsRunning}
            main{PhoneService.instance!!.merge()}
            waitFor("Screenshot conference did not connect"){PhoneService.instance?.conference?.participantCount==2}
            Thread.sleep(5000);main{PhoneService.instance!!.calls.forEach{assertTrue(it.audioStats!!.downloadBandwidth>0);assertTrue(it.audioStats!!.uploadBandwidth>0)}};capture("05-three-way.png")
        }finally{main{PhoneService.instance?.calls?.toList()?.forEach{PhoneService.instance?.hangup(it)};activity.finish()}}
    }
}
