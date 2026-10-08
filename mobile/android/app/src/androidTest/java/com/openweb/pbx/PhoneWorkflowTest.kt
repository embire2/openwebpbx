package com.openweb.pbx

import android.Manifest
import android.content.Intent
import android.os.Environment
import android.os.Build
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

/** Requires an explicitly supplied isolated live fixture; never contains customer credentials. */
@RunWith(AndroidJUnit4::class)
class PhoneWorkflowTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private fun onMain(action:()->Unit) = instrumentation.runOnMainSync(action)
    private fun await(label:String, timeout:Long=90000, condition:()->Boolean) {
        val end=System.currentTimeMillis()+timeout
        while(System.currentTimeMillis()<end){var ready=false;onMain{ready=condition()};if(ready)return;Thread.sleep(500)}
        var detail="";onMain{detail="${PhoneService.instance?.status} / ${PhoneService.instance?.core?.defaultAccount?.errorInfo?.reason} / ${PhoneService.instance?.core?.defaultAccount?.errorInfo?.protocolCode}"};fail("Timed out: $label ($detail)")
    }
    @org.junit.After fun closeTestCall() { onMain{PhoneService.instance?.hangup()};Thread.sleep(500) }
    @Test fun liveEnrollmentCallingControlsAndMailbox() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("liveFixture")=="true")
        val file=File(context.getExternalFilesDir(null),"live-fixture.json")
        val fixture=JSONObject(file.readText());file.delete()
        val enrollment=fixture.getJSONObject("enrollment")
        val device=UiDevice.getInstance(instrumentation)
        instrumentation.uiAutomation.executeShellCommand("pm grant com.openweb.pbx android.permission.RECORD_AUDIO").close()
        instrumentation.uiAutomation.executeShellCommand("pm grant com.openweb.pbx android.permission.CAMERA").close()
        if(Build.VERSION.SDK_INT>=33)instrumentation.uiAutomation.executeShellCommand("pm grant com.openweb.pbx android.permission.POST_NOTIFICATIONS").close()
        if(Build.VERSION.SDK_INT>=31)instrumentation.uiAutomation.executeShellCommand("pm grant com.openweb.pbx android.permission.BLUETOOTH_CONNECT").close()
        val reconnect=InstrumentationRegistry.getArguments().getString("reconnect")=="true"
        if(!reconnect)PhoneStore(context).clear()
        val activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        if(!reconnect){
        if(InstrumentationRegistry.getArguments().getString("qrFixture")=="true") {
            val bitmap=android.graphics.BitmapFactory.decodeFile(File(context.getExternalFilesDir(null),"server-qr.png").path)
            val pixels=IntArray(bitmap.width*bitmap.height);bitmap.getPixels(pixels,0,bitmap.width,0,0,bitmap.width,bitmap.height)
            val decoded=com.google.zxing.MultiFormatReader().decode(com.google.zxing.BinaryBitmap(com.google.zxing.common.HybridBinarizer(com.google.zxing.RGBLuminanceSource(bitmap.width,bitmap.height,pixels)))).text
            val scan=Intent().putExtra("SCAN_RESULT",decoded).putExtra("SCAN_RESULT_FORMAT","QR_CODE")
            // The decoder consumes the real PBX image; a monitor supplies its result instead of physical camera input.
            val monitor=instrumentation.addMonitor("com.journeyapps.barcodescanner.CaptureActivity",android.app.Instrumentation.ActivityResult(android.app.Activity.RESULT_OK,scan),true)
            try {
                assertNotNull(device.wait(Until.findObject(By.text("Scan QR code")),60000));device.findObject(By.text("Scan QR code")).click()
                assertNotNull(device.wait(Until.findObject(By.text("Connect your phone?")),15000))
                device.findObject(By.res("android:id/button1")).click()
            } finally { instrumentation.removeMonitor(monitor) }
        } else {
        assertNotNull(device.wait(Until.findObject(By.text("Enter a connection code instead")),60000))
        device.findObject(By.text("Enter a connection code instead")).click()
        assertNotNull(device.wait(Until.findObject(By.clazz("android.widget.EditText")),10000))
        val inputs=device.findObjects(By.clazz("android.widget.EditText"))
        assertEquals(2,inputs.size)
        inputs[0].text=enrollment.getString("server");inputs[1].text=enrollment.getString("code")
        device.findObject(By.text(java.util.regex.Pattern.compile("Connect",java.util.regex.Pattern.CASE_INSENSITIVE))).click()
        }
        await("enrollment saved") { PhoneStore(context).read()!=null }
        }
        await("TLS registration ready",120000) { run { val a=PhoneService.instance?.core?.defaultAccount; if(a?.state==org.linphone.core.RegistrationState.Failed)fail("Registration failed: ${a.errorInfo.reason}/${a.errorInfo.protocolCode}/${a.errorInfo.phrase}"); PhoneService.instance?.status=="Ready for calls" } }
        val phone=PhoneService.instance!!
        val saved=PhoneStore(context).read()!!
        val api=PhoneApi(saved.getString("server"),saved.getString("token"))
        assertTrue(api.json("directory").getJSONArray("contacts").length()>=2)
        assertNotNull(api.json("calls").getJSONArray("calls"))
        assertNotNull(api.json("voicemail").getJSONArray("messages"))
        onMain { phone.dial(fixture.optString("destination","1001")) }
        await("outgoing call answered",120000) { phone.call?.state==Call.State.StreamsRunning }
        onMain{activity.window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)}
        Thread.sleep(800);device.takeScreenshot(File(context.getExternalFilesDir(null),"native-call.png"))
        onMain { assertEquals(MediaEncryption.SRTP,phone.call!!.currentParams.mediaEncryption);phone.mute();assertTrue(phone.muted);phone.mute();assertFalse(phone.muted);phone.speaker();assertTrue("Speaker route",phone.speaker);if(phone.audioDevices().any{it.type==org.linphone.core.AudioDevice.Type.Earpiece}){phone.speaker();assertFalse("Earpiece route",phone.speaker)};phone.dtmf('5') }
        Thread.sleep(800);onMain{phone.hold()}
        await("hold") {phone.call?.state==Call.State.Paused}
        onMain {phone.hold()}
        await("resume") {phone.call?.state==Call.State.StreamsRunning}
        Thread.sleep(12000)
        onMain { assertTrue("Received media",phone.call!!.audioStats!!.downloadBandwidth>0);assertTrue("Sent media",phone.call!!.audioStats!!.uploadBandwidth>0);phone.hangup() }
        await("call ended"){phone.call==null}
        phone.flushPending();Thread.sleep(3000)
        assertTrue(api.json("calls").getJSONArray("calls").length()>0)
        // The fixture may carry seeded mailbox messages to prove audio/read/delete against the server.
        val messages=api.json("voicemail").getJSONArray("messages")
        if(messages.length()>0){
            val id=messages.getJSONObject(0).getString("id");assertTrue(api.voicemail(id).size>44)
            device.findObject(By.text("Voicemail").clazz("android.widget.Button")).click()
            assertNotNull(device.wait(Until.findObject(By.text("Play")),15000));device.findObject(By.text("Play")).click()
            val playerField=MainActivity::class.java.getDeclaredField("player").apply{isAccessible=true}
            await("native voicemail playback",10000){(playerField.get(activity) as? android.media.MediaPlayer)?.isPlaying==true}
            Thread.sleep(2300)
            assertTrue(api.json("voicemail").getJSONArray("messages").getJSONObject(0).getBoolean("read"))
            device.findObject(By.text("Delete")).click()
            assertNotNull(device.wait(Until.findObject(By.text("Delete this voicemail?")),10000))
            device.findObject(By.res("android:id/button1")).click()
            Thread.sleep(2000);assertEquals(0,api.json("voicemail").getJSONArray("messages").length())
        }
        device.findObject(By.text("Contacts").clazz("android.widget.Button")).click()
        assertNotNull(device.wait(Until.findObject(By.clazz("android.widget.EditText")),15000))
        device.findObject(By.clazz("android.widget.EditText")).text="1001"
        assertTrue(device.findObjects(By.clazz("android.widget.Button")).any{it.text?.contains("1001")==true})
        device.findObject(By.textContains("1001").clazz("android.widget.Button")).click()
        await("directory tap call answered"){phone.call?.state==Call.State.StreamsRunning}
        onMain{assertEquals("1001",phone.callLabel);phone.hangup()};await("directory call ended"){phone.call==null}
        Thread.sleep(2000)
        device.findObject(By.text("Recents").clazz("android.widget.Button")).click()
        assertNotNull(device.wait(Until.findObject(By.textContains("outgoing")),15000))
        device.findObject(By.textContains("outgoing")).click()
        await("Recents tap call answered"){phone.call?.state==Call.State.StreamsRunning}
        onMain{assertEquals("1001",phone.callLabel);phone.hangup()};await("Recents call ended"){phone.call==null}
        onMain{activity.window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)}
        device.takeScreenshot(File(context.getExternalFilesDir(null),"native-recents.png"))
    }
    @Test fun incomingNotificationAnswerAndMissedCall() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("incomingFixture")=="true")
        val device=UiDevice.getInstance(instrumentation)
        instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        await("incoming test registration",30000){PhoneService.instance?.status=="Ready for calls"}
        val phone=PhoneService.instance!!
        device.pressHome()
        File(context.getExternalFilesDir(null),"incoming-ready").writeText("ready")
        await("incoming call",90000){phone.call?.state==Call.State.IncomingReceived}
        val manager=context.getSystemService(android.app.NotificationManager::class.java)
        assertTrue("Incoming notification",manager.activeNotifications.any{it.id==11})
        device.openNotification()
        assertNotNull(device.wait(Until.findObject(By.text("Incoming call")),10000))
        device.findObject(By.text("Incoming call")).click()
        assertNotNull(device.wait(Until.findObject(By.text("Answer")),10000))
        device.findObject(By.text("Answer")).click()
        await("incoming answered"){phone.call?.state==Call.State.StreamsRunning}
        File(context.getExternalFilesDir(null),"incoming-answered").writeText("answered")
        Thread.sleep(2000);var beforeReceived=0L;var beforeSent=0L
        onMain{beforeReceived=phone.call!!.audioStats!!.rtpPacketRecv;beforeSent=phone.call!!.audioStats!!.rtpPacketSent}
        Thread.sleep(18000)
        onMain{assertEquals(MediaEncryption.SRTP,phone.call!!.currentParams.mediaEncryption);assertTrue("Sustained incoming received RTP",phone.call!!.audioStats!!.rtpPacketRecv-beforeReceived>300);assertTrue("Sustained incoming sent RTP",phone.call!!.audioStats!!.rtpPacketSent-beforeSent>300);assertTrue("Incoming live download",phone.call!!.audioStats!!.downloadBandwidth>0);assertTrue("Incoming live upload",phone.call!!.audioStats!!.uploadBandwidth>0);phone.hangup()}
        await("incoming ended"){phone.call==null}
        File(context.getExternalFilesDir(null),"missed-ready").writeText("ready")
        await("second incoming call",90000){phone.call?.state==Call.State.IncomingReceived}
        onMain{phone.hangup()};await("declined call ended"){phone.call==null}
        Thread.sleep(3000)
        val saved=PhoneStore(context).read()!!;val api=PhoneApi(saved.getString("server"),saved.getString("token"))
        val calls=api.json("calls").getJSONArray("calls")
        val directions=(0 until calls.length()).map{calls.getJSONObject(it).getString("direction")}
        assertTrue(directions.contains("incoming"));assertTrue(directions.contains("missed"))
    }

    @Test fun administratorRevokesAnActiveIncomingCall() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("revokeFixture")=="true")
        instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        await("revocation test registration",30000){PhoneService.instance?.status=="Ready for calls"}
        val phone=PhoneService.instance!!;val saved=PhoneStore(context).read()!!
        File(context.getExternalFilesDir(null),"revocation-ready").writeText("ready")
        await("revocation incoming call",60000){phone.call?.state==Call.State.IncomingReceived}
        onMain{phone.answer()};await("revocation call answered"){phone.call?.state==Call.State.StreamsRunning}
        File(context.getExternalFilesDir(null),"revocation-answered").writeText("answered")
        await("administrator ended revoked phone call",60000){phone.call==null}
        try { PhoneApi(saved.getString("server"),saved.getString("token")).json("bootstrap");fail("Revoked API token accepted") } catch(e:ApiError){assertEquals(401,e.status)}
        onMain{phone.core!!.refreshRegisters()}
        await("revoked phone registration rejected",30000){phone.core?.defaultAccount?.state==org.linphone.core.RegistrationState.Failed}
    }

}
