/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.app.NotificationManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.WindowManager
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

/** Opt-in capture of the real native UI using a dedicated, non-customer review account. */
@RunWith(AndroidJUnit4::class)
class ReviewAssetsTest {
    private val instrument get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrument.targetContext
    private val device get() = UiDevice.getInstance(instrument)
    private val output get() = File(context.getExternalFilesDir(null), "review-assets").apply { mkdirs() }
    private var frame = 0
    private fun main(block: () -> Unit) = instrument.runOnMainSync(block)
    private fun await(label: String, condition: () -> Boolean) {
        repeat(180) { var ready = false; main { ready = condition() }; if (ready) return; Thread.sleep(250) }
        fail(label)
    }
    private fun bitmap(activity: MainActivity): Bitmap {
        lateinit var result: Bitmap
        main {
            assertTrue("Production screen capture protection must remain enabled", activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
            val view = activity.window.decorView
            assertTrue(view.width > 0 && view.height > 0)
            result = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(result))
        }
        return result
    }
    private fun save(bitmap: Bitmap, name: String) {
        File(output, name).outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
    }
    private fun capture(activity: MainActivity, seconds: Int = 3, screenshot: String? = null, system: Boolean = false) {
        if (screenshot != null) save(bitmap(activity), "$screenshot.png")
        repeat(seconds * 4) {
            // System capture is used only for Android's own home/notification UI. The
            // app retains FLAG_SECURE; its actual view is drawn inside instrumentation.
            val image = if (system) instrument.uiAutomation.takeScreenshot() else bitmap(activity)
            assertNotNull("Native capture unavailable", image)
            save(image!!, "frame-%05d.png".format(frame++))
            Thread.sleep(250)
        }
    }
    private fun dialVisible(activity: MainActivity, number: String) {
        device.findObject(By.text("Dismiss"))?.click()
        device.findObject(By.desc("Number or extension")).text = ""
        for (digit in number) {
            device.findObject(By.desc(digit.toString())).click()
            capture(activity, 1)
        }
        device.findObject(By.desc("Call")).click()
    }
    @Test fun demoEnrollmentCallingAndForegroundServiceEvidence() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("reviewFixture") == "true")
        assumeTrue("Use an account-free review installation", PhoneStore(context).read() == null)
        val setupFile = File(context.getExternalFilesDir(null), "review-setup.json")
        val setup = JSONObject(setupFile.readText())
        require(setup.getString("purpose") == "isolated-store-review")
        val activity = instrument.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        try {
            Thread.sleep(1000)
            capture(activity, screenshot = "01-connect")
            val server = setup.getString("server")
            val account = PhoneApi(server).json("enroll", JSONObject().put("code", setup.getString("code")).put("device_name", "Store review validation").put("platform", "android")).put("server", server)
            require(account.getJSONObject("account").getString("extension") == "7001")
            PhoneStore(context).save(account); setupFile.delete()
            await("Demo phone did not register") { PhoneService.instance?.status == "Ready for calls" }
            capture(activity, screenshot = "02-keypad")
            assertTrue(context.getSystemService(NotificationManager::class.java).activeNotifications.any { it.id == 10 })
            // Android may refuse a SystemUI screenshot while a secure application is
            // composited underneath its drawer. Show Home first, without weakening
            // the application's secure flag, as in an ordinary background call.
            device.pressHome(); Thread.sleep(800)
            device.openNotification(); Thread.sleep(800); capture(activity, system = true)
            device.pressBack()
            main { context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            Thread.sleep(500)
            device.findObject(By.desc("Contacts")).click()
            assertNotNull(device.wait(Until.findObject(By.clazz("android.widget.EditText")), 10000))
            Thread.sleep(1000); capture(activity, screenshot = "03-contacts")
            device.findObject(By.desc("Voicemail")).click()
            assertNotNull(device.wait(Until.findObject(By.text("Play")), 10000))
            device.findObject(By.text("Play")).click()
            val player = MainActivity::class.java.getDeclaredField("player").apply { isAccessible = true }
            await("Demo voicemail did not play") { (player.get(activity) as? android.media.MediaPlayer)?.isPlaying == true }
            capture(activity, 2, "05-voicemail")
            device.findObject(By.desc("Keypad")).click()
            dialVisible(activity, "7000")
            await("Demo echo call not answered") { PhoneService.instance?.call?.state == Call.State.StreamsRunning }
            capture(activity, 8, "04-call")
            main {
                val call = PhoneService.instance!!.call!!
                assertEquals(MediaEncryption.SRTP, call.currentParams.mediaEncryption)
                assertTrue(call.audioStats!!.uploadBandwidth > 0)
                assertTrue(call.audioStats!!.downloadBandwidth > 0)
            }
            device.pressHome(); Thread.sleep(500); capture(activity, 2, system = true)
            device.openNotification(); Thread.sleep(800); capture(activity, 4, system = true)
            main { assertEquals(Call.State.StreamsRunning, PhoneService.instance!!.call!!.state) }
            device.pressBack()
            main { context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            Thread.sleep(500); capture(activity, 2)
            device.findObject(By.desc("End call")).click()
            await("Call not ended") { PhoneService.instance?.call == null }
            capture(activity, 2)
            if (InstrumentationRegistry.getArguments().getString("reviewIncoming") == "true") {
                File(output, "incoming-ready.txt").writeText("ready")
                await("Review portal incoming call not delivered") { PhoneService.instance?.call?.state == Call.State.IncomingReceived }
                capture(activity, 2, "06-incoming")
                device.findObject(By.desc("Answer")).click()
                await("Review incoming call was not answered") { PhoneService.instance?.call?.state == Call.State.StreamsRunning }
                capture(activity, 8)
                main {
                    val call = PhoneService.instance!!.call!!
                    assertEquals(MediaEncryption.SRTP, call.currentParams.mediaEncryption)
                    assertTrue(call.audioStats!!.uploadBandwidth > 0)
                    assertTrue(call.audioStats!!.downloadBandwidth > 0)
                }
                device.findObject(By.desc("End call")).click()
                await("Review incoming call did not end") { PhoneService.instance?.call == null }
            }
            val api = PhoneApi(server, account.getString("token"))
            fun mailbox() = api.json("voicemail").getJSONArray("messages")
            val before = mailbox().let { rows -> (0 until rows.length()).map { rows.getJSONObject(it).getString("id") }.toSet() }
            File(output, "voicemail-ready.txt").writeText("ready") // Host may provide a synthetic microphone tone.
            dialVisible(activity, "7002")
            await("Demo voicemail call not answered") { PhoneService.instance?.call?.state == Call.State.StreamsRunning }
            capture(activity, 22)
            device.findObject(By.desc("End call")).click()
            await("Voicemail recording call did not end") { PhoneService.instance?.call == null }
            var fresh: String? = null
            repeat(60) {
                if (fresh == null) {
                    val rows = mailbox()
                    fresh = (0 until rows.length()).map { rows.getJSONObject(it).getString("id") }.firstOrNull { it !in before }
                    if (fresh == null) Thread.sleep(500)
                }
            }
            assertNotNull("Calling7002 must create a real new voicemail", fresh)
            File(output, "created-voicemail-private.txt").writeText(fresh!!)
            try {
                val recordedAudio = api.voicemail(fresh!!)
                assertTrue("Fresh recorded voicemail has audio", recordedAudio.size > 1000)
                // Private fixture evidence permits signal verification after the
                // message is removed through the real Android deletion control.
                File(output, "recorded-audio-private.wav").writeBytes(recordedAudio)
                device.findObject(By.desc("Voicemail")).click()
                assertNotNull(device.wait(Until.findObject(By.text("Play")), 10000))
                assertEquals("New recording is shown first", fresh, mailbox().getJSONObject(0).getString("id"))
                device.findObject(By.text("Play")).click()
                await("Fresh voicemail did not play in Android") { (player.get(activity) as? android.media.MediaPlayer)?.isPlaying == true }
                capture(activity, 3, "07-recorded-voicemail")
                device.findObject(By.text("Delete")).click()
                assertNotNull(device.wait(Until.findObject(By.text("Delete this voicemail?")), 5000))
                device.findObject(By.res("android:id/button1")).click()
                var removed = false
                repeat(40) {
                    if (!removed) {
                        val rows = mailbox(); removed = (0 until rows.length()).none { rows.getJSONObject(it).getString("id") == fresh }
                        if (!removed) Thread.sleep(250)
                    }
                }
                assertTrue("Fresh voicemail deletion completed", removed)
                assertEquals("Existing review samples are preserved", before, mailbox().let { rows -> (0 until rows.length()).map { rows.getJSONObject(it).getString("id") }.toSet() })
            } finally {
                val rows = mailbox()
                if ((0 until rows.length()).any { rows.getJSONObject(it).getString("id") == fresh }) api.json("voicemail_delete", JSONObject().put("id", fresh))
            }
            device.findObject(By.desc("Keypad")).click()
            // Reserved fictional number; the review PBX has no carrier or external routes.
            main { PhoneService.instance!!.dial("+12025550123") }
            await("Review PBX must refuse external numbers") { PhoneService.instance?.call == null && PhoneService.instance?.lastCallMessage?.isNotEmpty() == true }
            device.findObject(By.text("Settings")).click()
            assertNotNull(device.wait(Until.findObject(By.res("android:id/button2")), 5000))
            device.findObject(By.res("android:id/button2")).click()
            assertNotNull(device.wait(Until.findObject(By.text("Disconnect this phone?")), 5000))
            device.findObject(By.res("android:id/button1")).click()
            await("Demo phone was not disconnected") { PhoneStore(context).read() == null && PhoneService.instance == null }
            assertFalse(context.getSystemService(NotificationManager::class.java).activeNotifications.any { it.id == 10 })
            capture(activity, 3)
            File(output, "evidence.json").writeText(JSONObject().put("frames", frame).put("fps", 4).put("secure_flag_preserved", true).put("enrollment", "real isolated review API").put("media", "SRTP in both directions").put("background_call", true).put("visible_keypad_call", true).put("sample_voicemail_played", true).put("fresh_voicemail_record_play_delete", true).put("external_call_refused", true).put("incoming_checked", InstrumentationRegistry.getArguments().getString("reviewIncoming") == "true").put("disconnected", true).toString())
        } finally { main { PhoneService.instance?.hangup(); activity.finish() } }
    }
}
