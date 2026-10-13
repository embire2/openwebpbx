/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.RingtoneManager
import android.net.Uri
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.activity.result.ActivityResult
import androidx.activity.result.ActivityResultCallback
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.contract.ActivityResultContracts
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiScrollable
import androidx.test.uiautomator.UiSelector
import androidx.test.uiautomator.Until
import org.junit.After
import org.junit.Rule
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import org.json.JSONArray
import org.json.JSONObject
import org.linphone.core.Call
import org.linphone.core.Core
import java.io.File
import java.security.MessageDigest

/** Owned disposable PBX only. Independent SIP peers verify the exported media phases. */
@RunWith(AndroidJUnit4::class)
class PersonalControlsTest {
    private var owned=false
    private val instrument get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrument.targetContext
    private val device get()=UiDevice.getInstance(instrument)
    private val files get()=context.getExternalFilesDir(null)!!
    @get:Rule val failureEvidence=object:TestWatcher(){
        override fun failed(error:Throwable,description:Description){
            if(!owned)return
            device.dumpWindowHierarchy(File(files,"personal-controls-failure.xml"))
            main{
                val visible=ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull() ?: return@main
                val view=visible.window.decorView
                val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
                view.draw(Canvas(bitmap))
                File(files,"personal-controls-failure.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
                bitmap.recycle()
            }
        }
    }
    private fun main(block:()->Unit)=instrument.runOnMainSync(block)
    private fun waitFor(label:String,seconds:Int=45,test:()->Boolean){
        val end=System.currentTimeMillis()+seconds*1000
        while(System.currentTimeMillis()<end){var ready=false;main{ready=test()};if(ready)return;Thread.sleep(250)}
        fail(label)
    }
    private fun activity()=ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().first()
    private fun connect(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("personalControlsFixture")=="true")
        val account=PhoneStore(context).read() ?: error("Enroll the owned fixture first")
        require(account.getJSONObject("sip").getString("domain").matches(Regex("mobile-check-[a-f0-9]{12}\\.invalid")))
        owned=true
        device.wakeUp();device.pressMenu()
        main{context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}
        waitFor("Owned phone did not register",90){PhoneService.instance?.status=="Ready for calls"}
    }
    private fun click(text:String){
        val control=device.wait(Until.findObject(By.text(text)),12000) ?: error("Native control unavailable: $text")
        assertTrue("Native control disabled: $text",control.isEnabled);control.click()
    }
    private fun item(title:String){
        if(!device.hasObject(By.descStartsWith("$title, ")))
            UiScrollable(UiSelector().className("android.widget.ScrollView")).scrollIntoView(UiSelector().descriptionStartsWith("$title, "))
        val control=device.wait(Until.findObject(By.descStartsWith("$title, ")),5000) ?: error("Settings item unavailable: $title")
        control.click()
    }
    private fun choose(value:String){
        val option=device.wait(Until.findObject(By.text(value).clazz("android.widget.CheckedTextView")),5000)
            ?: error("Native choice unavailable: $value")
        option.click()
    }
    private fun closeDialog(){device.findObject(By.res("android:id/button1")).click()}
    private fun settings(){click("Settings");assertNotNull(device.wait(Until.findObject(By.text("Make this phone your own")),5000))}
    private fun phase(name:String){
        val state=JSONObject().put("phase",name)
        main{
            val phone=PhoneService.instance
            state.put("conference_on_hold",phone?.conferenceOnHold).put("conference_joined",phone?.conference?.isIn).put("conference_state",phone?.conference?.state?.toString())
            state.put("calls",JSONArray(phone?.calls?.map{call->
                val stats=call.audioStats
                JSONObject().put("number",call.remoteAddress.username).put("state",call.state.toString())
                    .put("direction",call.currentParams.audioDirection.toString()).put("remote_direction",call.remoteParams?.audioDirection?.toString())
                    .put("local_conference",call.currentParams.localConferenceMode).put("conference_joined",call.conference?.isIn)
                    .put("download_kbps",stats?.downloadBandwidth).put("upload_kbps",stats?.uploadBandwidth)
                    .put("rtp_packets_received",stats?.rtpPacketRecv).put("rtp_packets_sent",stats?.rtpPacketSent)
                    .put("rtp_received_bytes",stats?.rtpRecv).put("rtp_hardware_received_bytes",stats?.rtpHwRecv).put("rtp_discarded",stats?.rtpDiscarded)
            } ?: emptyList<JSONObject>()))
        }
        File(files,"personal-controls-states.jsonl").appendText(state.toString()+"\n")
        File(files,"personal-controls-phase.txt").writeText(name)
    }
    private fun core()=PhoneService::class.java.getDeclaredField("core").apply{isAccessible=true}.get(PhoneService.instance) as Core
    private fun counters():Map<Long,Pair<Long,Long>>{
        var values=emptyMap<Long,Pair<Long,Long>>()
        main{values=PhoneService.instance!!.calls.associate{val stats=it.audioStats!!;it.nativePointer to (stats.rtpPacketRecv to stats.rtpPacketSent)}}
        return values
    }
    private fun advancing(before:Map<Long,Pair<Long,Long>>){
        val after=counters();assertEquals("A media leg changed unexpectedly",before.keys,after.keys)
        before.forEach{(pointer,prior)->val current=after.getValue(pointer);assertTrue("Decoded incoming RTP did not advance",current.first-prior.first>100);assertTrue("Outgoing native RTP did not advance",current.second-prior.second>100)}
    }
    private fun media(){phase("media-observation");main{PhoneService.instance!!.calls.forEach{assertTrue("Incoming native media missing",it.audioStats!!.downloadBandwidth>0);assertTrue("Outgoing native media missing",it.audioStats!!.uploadBandwidth>0)}}}
    private fun first(){connect();main{PhoneService.instance!!.dial("1001")};waitFor("First owned peer did not answer"){PhoneService.instance?.call?.state==Call.State.StreamsRunning};Thread.sleep(3500)}
    @After fun cleanup(){
        if(!owned)return
        phase("finished")
        main{PhoneService.instance?.calls?.toList()?.forEach{PhoneService.instance?.hangup(it)}}
        Thread.sleep(1200)
    }
    @Test fun settingsPersistResetAndKeepAccount(){
        connect()
        val before=MessageDigest.getInstance("SHA-256").digest(PhoneStore(context).read()!!.getString("token").toByteArray())
        val updates=context.getSharedPreferences("application_updates",0)
        val trustBefore=updates.getLong("highest_sequence",0) to updates.getString("highest_digest",null)
        val prefs=PhonePreferences(context)
        try {
            settings();item("Choose theme");choose("Dark");waitFor("Dark theme preference missing"){prefs.theme=="Dark"}
            var darkColor=0;main{darkColor=activity().window.statusBarColor}
            item("Choose theme");choose("Light");waitFor("Light theme preference missing"){prefs.theme=="Light"}
            main{assertNotEquals("Theme did not change the native screen",darkColor,activity().window.statusBarColor)}
            item("Choose theme");choose("System");waitFor("System theme preference missing"){prefs.theme=="System"}
            item("Choose theme");choose("Light")
            item("Keypad vibration");assertFalse(prefs.keypadHaptics)
            item("Start page");choose("Contacts");waitFor("Startup choice not saved"){prefs.startupPage=="Contacts"}
            item("Sort contacts");choose("Name");click("Done")
            main{activity().finish();context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}
            assertNotNull(device.wait(Until.findObject(By.text("Your company directory")),12000))
            fun contactOrder():List<String>{
                var rows=emptyList<String>()
                val inspect={
                    fun collect(view:View):List<String> = when(view){is Button->listOf(view.text.toString());is ViewGroup->(0 until view.childCount).flatMap{collect(view.getChildAt(it))};else->emptyList()}
                    rows=collect(activity().window.decorView).mapNotNull{Regex("\\n(100[0-2])(?:\\s|$)").find(it)?.groupValues?.get(1)}
                }
                if(Looper.myLooper()==Looper.getMainLooper())inspect()else main(inspect)
                return rows
            }
            waitFor("Fixture directory rows missing"){contactOrder().size==3}
            assertEquals(listOf("1000","1002","1001"),contactOrder())
            settings();item("Sort contacts");choose("Extension");click("Done")
            waitFor("Extension sorting did not refresh"){contactOrder()==listOf("1000","1001","1002")}
            assertEquals("Light",prefs.theme);assertFalse(prefs.keypadHaptics)
            for(page in PhonePreferenceRules.pages){
                settings();item("Start page");choose(page);click("Done")
                main{activity().finish();context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}
                waitFor("Native startup page did not open: $page"){
                    ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull()
                        ?.let{MainActivity::class.java.getDeclaredField("section").apply{isAccessible=true}.get(it)==page} ?: false
                }
                assertEquals(page,PhonePreferences(context).startupPage)
            }
            settings();item("Ringtone")
            assertNotNull(device.wait(Until.findObject(By.text("Choose ringtone")),12000))
            assertFalse("Silent ringtone must not be offered",device.hasObject(By.text("Silent")))
            val sound=device.findObjects(By.clazz("android.widget.CheckedTextView")).firstOrNull{!it.text.startsWith("Default",true) && it.text !in listOf("Silent","None")}
                ?: error("Owned Android image has no built-in ringtone")
            sound.click();closeDialog()
            waitFor("Selected ringtone URI was not saved"){prefs.ringtoneUri()!=null}
            val selected=prefs.ringtoneUri()!!.toString()
            var selectedCore=0L;main{selectedCore=core().nativePointer}
            main{assertEquals("SDK did not receive the selected sound",selected,core().ring);assertTrue("SDK must remain sole ringer",core().isNativeRingingEnabled)}
            phase("settings-ringtone-incoming")
            waitFor("Incoming call with selected ringtone did not arrive",45){PhoneService.instance?.call?.state==Call.State.IncomingReceived}
            Thread.sleep(2500);main{assertEquals(selected,core().ring);assertTrue(core().isNativeRingingEnabled)}
            click("Answer");waitFor("Incoming ringtone call did not answer"){PhoneService.instance?.call?.state==Call.State.StreamsRunning}
            phase("settings-ringtone-answered");Thread.sleep(7000);media()
            main{PhoneService.instance!!.hangup()};waitFor("Incoming preference call did not end"){PhoneService.instance?.calls?.isEmpty()==true}
            main{context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}
            assertEquals(selected,PhonePreferences(context).ringtoneUri()!!.toString())
            // A removed sound must fall back without changing the account or disabling ringing.
            context.getSharedPreferences("phone_preferences",0).edit().putString("ringtone","content://media/external/audio/media/2147483647").commit()
            assertNull(prefs.ringtoneUri());assertEquals("System ringtone",prefs.ringtoneName())
            main{assertEquals("Fixture must exercise a cached sound",selected,core().ring)}
            phase("settings-missing-ringtone-incoming")
            waitFor("Incoming call after removed ringtone did not arrive",45){PhoneService.instance?.call?.state==Call.State.IncomingReceived}
            main{assertNull("Unavailable cached ringtone did not fall back before ringing",core().ring);assertTrue(core().isNativeRingingEnabled);assertEquals("Ringtone fallback restarted the native phone",selectedCore,core().nativePointer)}
            Thread.sleep(2000);click("Answer");waitFor("Fallback ringtone call did not answer"){PhoneService.instance?.call?.state==Call.State.StreamsRunning}
            phase("settings-fallback-answered");val fallback=counters();Thread.sleep(7000);media();advancing(fallback)
            main{PhoneService.instance!!.hangup()};waitFor("Fallback call did not end"){PhoneService.instance?.calls?.isEmpty()==true}
            main{context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}
            main{prefs.setRingtone(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE));PhoneService.instance!!.applyPersonalPreferences()}
            assertNull(prefs.ringtoneUri())
            item("Check connection");assertNotNull(device.wait(Until.findObject(By.text("Connection check")),12000));closeDialog()
            item("Reset personal settings")
            assertNotNull(device.wait(Until.findObject(By.text("Reset personal settings?")),5000))
            closeDialog()
            waitFor("Personal preferences not reset"){prefs.theme=="System" && prefs.startupPage=="Keypad" && prefs.contactSort=="Name" && prefs.keypadHaptics}
            main{assertNull("Reset did not restore system ringtone",core().ring);assertTrue(core().isNativeRingingEnabled)}
            assertTrue(before.contentEquals(MessageDigest.getInstance("SHA-256").digest(PhoneStore(context).read()!!.getString("token").toByteArray())))
            assertEquals("Reset changed update trust",trustBefore,updates.getLong("highest_sequence",0) to updates.getString("highest_digest",null))
            waitFor("Reset disconnected the account"){PhoneService.instance?.status=="Ready for calls"}
            click("Done");device.findObject(By.desc("Keypad")).click()
            main{PhoneService.instance!!.dial("1001")};waitFor("Calling after reset failed"){PhoneService.instance?.call?.state==Call.State.StreamsRunning};Thread.sleep(5000);media()
            File(files,"settings-controls-verified.txt").writeText("Actual native theme/haptics/start page/contact sort/picker/default fallback/check/reset retained enrolled account and calling.\n")
        }finally{main{prefs.reset();PhoneService.instance?.applyPersonalPreferences()}}
    }
    @Test fun visibleSingleHoldAcrossPages(){
        first()
        val accountBefore=MessageDigest.getInstance("SHA-256").digest(PhoneStore(context).read()!!.getString("token").toByteArray())
        for(page in listOf("Keypad","Contacts","Recents","Voicemail")){
            device.findObject(By.desc(page)).click()
            val hold=device.wait(Until.findObject(By.text("Call Hold")),5000)
            assertNotNull("Visible hold missing on $page",hold);assertTrue(hold!!.isEnabled)
            assertTrue("Hold is not full width",hold.visibleBounds.width()>device.displayWidth*0.75)
        }
        click("Call Hold");waitFor("Visible hold did not pause SIP leg"){PhoneService.instance?.call?.state==Call.State.Paused}
        phase("single-held");Thread.sleep(20000)
        settings();assertNotNull(device.wait(Until.findObject(By.text("Resume Call")),5000));item("Check connection")
        assertNotNull(device.wait(Until.findObject(By.text("Connection check")),12000));closeDialog()
        main{assertEquals(Call.State.Paused,PhoneService.instance!!.call!!.state)}
        item("Choose theme");choose("Dark");item("Reset personal settings")
        assertNotNull(device.wait(Until.findObject(By.text("Reset personal settings?")),5000));closeDialog()
        waitFor("Reset lost the held call"){PhoneService.instance?.call?.state==Call.State.Paused && PhonePreferences(context).theme=="System"}
        assertTrue("Reset during hold changed enrollment",accountBefore.contentEquals(MessageDigest.getInstance("SHA-256").digest(PhoneStore(context).read()!!.getString("token").toByteArray())))
        phase("single-resuming");click("Resume Call");waitFor("Visible resume did not restore call"){PhoneService.instance?.call?.state==Call.State.StreamsRunning}
        phase("single-resumed");val resumed=counters();Thread.sleep(7000);media();advancing(resumed)
        File(files,"visible-single-hold-verified.txt").writeText("Native full-width Hold/Resume visible across every call tab and Settings; SIP paused until explicit Resume with media.\n")
    }
    @Test fun conferenceHoldBothLegsAndRemoteDeparture(){
        first();main{PhoneService.instance!!.dial("1002",true)}
        waitFor("Second owned peer did not answer"){PhoneService.instance?.calls?.size==2 && PhoneService.instance?.call?.state==Call.State.StreamsRunning}
        main{PhoneService.instance!!.merge()};waitFor("Two-person conference did not form"){PhoneService.instance?.conference?.participantCount==2}
        Thread.sleep(5000);media();click("Call Hold")
        waitFor("Both conference SIP legs did not pause"){PhoneService.instance?.conferenceOnHold==true && PhoneService.instance!!.calls.size==2 && PhoneService.instance!!.calls.all{it.state==Call.State.Paused}}
        phase("conference-held");Thread.sleep(20000)
        main{assertTrue(PhoneService.instance!!.calls.all{it.state==Call.State.Paused})}
        phase("conference-resuming");click("Resume Call");waitFor("Conference resume did not merge both peers with local audio"){
            PhoneService.instance?.conference?.participantCount==2 && PhoneService.instance?.conferenceOnHold==false && PhoneService.instance?.conference?.isIn==true && PhoneService.instance!!.calls.all{it.state==Call.State.StreamsRunning}
        }
        Thread.sleep(2500);phase("conference-resumed");val resumed=counters();Thread.sleep(8000);phase("conference-resumed-observation");media();advancing(resumed)
        click("Call Hold");waitFor("Second conference hold incomplete"){PhoneService.instance?.conferenceOnHold==true && PhoneService.instance!!.calls.all{it.state==Call.State.Paused}}
        phase("remote-departure-request")
        waitFor("Owned remote peer did not depart",30){PhoneService.instance?.calls?.size==1}
        main{assertTrue(PhoneService.instance!!.conferenceOnHold);assertEquals(Call.State.Paused,PhoneService.instance!!.call!!.state)}
        phase("remaining-held");Thread.sleep(10000)
        main{assertEquals("Remaining caller resumed without explicit action",Call.State.Paused,PhoneService.instance!!.call!!.state)}
        phase("remaining-resuming");click("Resume Call");waitFor("Remaining caller failed to resume"){PhoneService.instance?.call?.state==Call.State.StreamsRunning && PhoneService.instance?.conferenceOnHold==false}
        phase("remaining-resumed");val remaining=counters();Thread.sleep(7000);media();advancing(remaining)
        File(files,"conference-hold-verified.txt").writeText("Both actual SIP legs paused; visible Resume rebuilt conference; remote departure left remaining leg paused until explicit Resume.\n")
    }
    @Test fun manualHoldSwitchBackRecoversOriginal(){
        first();var original:Call?=null;var second:Call?=null
        main{original=PhoneService.instance!!.call}
        click("Call Hold");waitFor("Manual hold did not pause original"){original!!.state==Call.State.Paused}
        main{PhoneService.instance!!.dial("1002",true)}
        waitFor("Second owned conversation did not connect"){PhoneService.instance?.calls?.size==2 && PhoneService.instance?.call?.state==Call.State.StreamsRunning}
        main{second=PhoneService.instance!!.call}
        click("Switch");waitFor("Switch did not explicitly resume held original"){PhoneService.instance?.call?.nativePointer==original!!.nativePointer && original!!.state==Call.State.StreamsRunning}
        Thread.sleep(2000);click("Switch")
        waitFor("Switch-back did not hold original automatically"){PhoneService.instance?.call?.nativePointer==second!!.nativePointer && second!!.state==Call.State.StreamsRunning && original!!.state==Call.State.Paused}
        val end=device.wait(Until.findObject(By.desc("End call")),5000) ?: error("Visible end control unavailable")
        end.click()
        waitFor("Ending second conversation failed to recover original automatically"){PhoneService.instance?.calls?.size==1 && PhoneService.instance?.call?.nativePointer==original!!.nativePointer && original!!.state==Call.State.StreamsRunning}
        phase("manual-switch-recovered");val restored=counters();Thread.sleep(7000);media();advancing(restored)
        File(files,"manual-hold-switch-verified.txt").writeText("Visible manual Hold, Switch, Switch-back and End-second automatically recovered the original with decoded two-way native RTP.\n")
    }
    @Test fun releasePersonalControlsScreenshots(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("storeScreenshots")=="true")
        connect();val prefs=PhonePreferences(context);val output=File(files,"release-assets").apply{mkdirs()}
        fun capture(name:String){
            main{
                val activity=activity();assertTrue(activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE!=0)
                val panel=MainActivity::class.java.getDeclaredField("updatePanel").apply{isAccessible=true}.get(activity) as ViewGroup
                if(panel.childCount==0)panel.visibility=View.GONE
                val view=activity.window.decorView
                view.measure(View.MeasureSpec.makeMeasureSpec(view.width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(view.height,View.MeasureSpec.EXACTLY))
                view.layout(0,0,view.width,view.height)
                val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
                view.draw(Canvas(bitmap));File(output,name).outputStream().use{assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))};bitmap.recycle()
            }
        }
        try{
            settings();item("Choose theme");choose("Light");Thread.sleep(600);capture("06-settings.png")
            item("Choose theme");choose("Dark");Thread.sleep(600);capture("08-settings-dark.png")
            item("Choose theme");choose("Light");click("Done");device.findObject(By.desc("Keypad")).click()
            main{PhoneService.instance!!.dial("1001")};waitFor("Screenshot call did not answer"){PhoneService.instance?.call?.state==Call.State.StreamsRunning}
            Thread.sleep(3500);click("Call Hold");waitFor("Screenshot caller did not hold"){PhoneService.instance?.call?.state==Call.State.Paused}
            Thread.sleep(1000);capture("07-call-held.png")
        }finally{main{prefs.reset();PhoneService.instance?.applyPersonalPreferences()}}
    }
    @Test fun ringtonePickerResultDiagnostic(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("ringtoneDiagnostic")=="true")
        connect();settings()
        var wrapped=false
        main{
            val registry=activity().activityResultRegistry
            fun capture(callback:ActivityResultCallback<ActivityResult>)=ActivityResultCallback<ActivityResult>{result->
                @Suppress("DEPRECATION") val uri=result.data?.getParcelableExtra<Uri>(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
                File(files,"ringtone-picker-result.json").writeText(JSONObject().put("result_code",result.resultCode).put("uri",uri?.toString()).put("flags",result.data?.flags).put("accepted_by_current_rule",uri?.let{PhonePreferenceRules.ringtone(it.toString())}).toString())
                callback.onActivityResult(result)
            }
            val containers=ActivityResultRegistry::class.java.getDeclaredField("keyToLifecycleContainers").apply{isAccessible=true}.get(registry) as Map<*,*>
            for(container in containers.values){
                val observers=container!!::class.java.getDeclaredField("observers").apply{isAccessible=true}.get(container) as List<*>
                for(observer in observers){
                    val fields=observer!!::class.java.declaredFields.onEach{it.isAccessible=true}
                    if(fields.none{it.get(observer) is ActivityResultContracts.StartActivityForResult})continue
                    val callbackField=fields.first{it.get(observer) is ActivityResultCallback<*>}
                    @Suppress("UNCHECKED_CAST") val callback=callbackField.get(observer) as ActivityResultCallback<ActivityResult>
                    callbackField.set(observer,capture(callback))
                    wrapped=true
                }
            }
            val callbacks=ActivityResultRegistry::class.java.getDeclaredField("keyToCallback").apply{isAccessible=true}.get(registry) as Map<*,*>
            for(pair in callbacks.values){
                val contract=pair!!::class.java.getDeclaredField("contract").apply{isAccessible=true}.get(pair)
                if(contract !is ActivityResultContracts.StartActivityForResult)continue
                val field=pair::class.java.getDeclaredField("callback").apply{isAccessible=true}
                @Suppress("UNCHECKED_CAST") val original=field.get(pair) as ActivityResultCallback<ActivityResult>
                field.set(pair,capture(original));wrapped=true
            }
        }
        assertTrue("Picker result capture unavailable",wrapped)
        item("Ringtone");assertNotNull(device.wait(Until.findObject(By.text("Choose ringtone")),12000))
        device.findObjects(By.clazz("android.widget.CheckedTextView")).first{!it.text.startsWith("Default",true) && it.text !in listOf("Silent","None")}.click()
        closeDialog();waitFor("Actual picker result unavailable",15){File(files,"ringtone-picker-result.json").exists()}
        device.dumpWindowHierarchy(File(files,"ringtone-picker-return.xml"))
    }
}
