package com.openweb.pbx

import android.content.Intent
import android.media.MediaPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit

/** Device regression checks using only an explicitly connected disposable account. */
@RunWith(AndroidJUnit4::class)
class ActivityLifecycleTest {
    private val i get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=i.targetContext
    private fun main(f:()->Unit)=i.runOnMainSync(f)
    private fun await(label:String,test:()->Boolean){repeat(80){var ok=false;main{ok=test()};if(ok)return;Thread.sleep(250)};fail(label)}
    private fun activity()=i.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
    @Test fun replacementActivityObservesCompletedEnrollment() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("lifecycleFixture")=="true")
        val store=PhoneStore(context);val saved=store.read()!!
        main{context.stopService(Intent(context,PhoneService::class.java))};await("phone stopped"){PhoneService.instance==null};store.clear()
        val old=activity();main{old.recreate()}
        await("replacement activity resumed"){ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).any{it is MainActivity && it!==old}}
        // This is the worker's durable completion while the original Activity no longer exists.
        Thread{store.save(saved)}.apply{start();join()}
        await("replacement activity connects saved account"){PhoneService.instance?.status=="Ready for calls"}
        assertEquals(saved.getString("token"),store.read()!!.getString("token"))
    }
    @Test fun canceledAndRepeatedVoicemailDownloadsDoNotLeavePlayers() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("lifecycleFixture")=="true")
        val saved=PhoneStore(context).read()!!;val api=PhoneApi(saved.getString("server"),saved.getString("token"))
        val messages=api.json("voicemail").getJSONArray("messages");assertTrue("Seed a disposable voicemail",messages.length()>0)
        val id=messages.getJSONObject(0).getString("id");val a=activity()
        val section=MainActivity::class.java.getDeclaredField("section").apply{isAccessible=true}
        val player=MainActivity::class.java.getDeclaredField("player").apply{isAccessible=true}
        val worker=MainActivity::class.java.getDeclaredField("worker").apply{isAccessible=true}.get(a) as ExecutorService
        val draw=MainActivity::class.java.getDeclaredMethod("draw").apply{isAccessible=true}
        val play=MainActivity::class.java.getDeclaredMethod("playVoicemail",String::class.java).apply{isAccessible=true}
        val stop=MainActivity::class.java.getDeclaredMethod("stopPlayback").apply{isAccessible=true}
        main{section.set(a,"Voicemail");draw.invoke(a);play.invoke(a,id);stop.invoke(a);section.set(a,"Contacts");draw.invoke(a)}
        worker.submit{}.get(30,TimeUnit.SECONDS);i.waitForIdleSync()
        main{assertNull("Canceled download must not start audio",player.get(a))}
        assertEquals(0,context.cacheDir.listFiles()?.count{it.name.startsWith("voicemail-")} ?: 0)
        main{section.set(a,"Voicemail");draw.invoke(a);play.invoke(a,id);play.invoke(a,id)}
        await("latest requested voicemail plays"){(player.get(a) as? MediaPlayer)?.isPlaying==true}
        assertEquals("Only the current audio file is retained",1,context.cacheDir.listFiles()?.count{it.name.startsWith("voicemail-")} ?: 0)
        main{stop.invoke(a)};assertEquals(0,context.cacheDir.listFiles()?.count{it.name.startsWith("voicemail-")} ?: 0)
    }
    @Test fun revokedPhoneCanDisconnectLocally() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("logoutFixture")=="true")
        val store=PhoneStore(context);val revoked=store.read()!!
        try { PhoneApi(revoked.getString("server"),revoked.getString("token")).json("bootstrap");fail("Fixture phone must already be revoked") }catch(e:ApiError){assertEquals(401,e.status)}
        store.clear();val a=activity()
        // Preserve the active account screen, matching administrator revocation while that screen is already open.
        main{MainActivity::class.java.getDeclaredField("bootstrapped").apply{isAccessible=true}.setBoolean(a,true);store.save(revoked)}
        val device=androidx.test.uiautomator.UiDevice.getInstance(i)
        assertNotNull(device.wait(androidx.test.uiautomator.Until.findObject(androidx.test.uiautomator.By.text("Settings")),10000))
        main{a.window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)}
        Thread.sleep(700);device.takeScreenshot(java.io.File(context.getExternalFilesDir(null),"native-short-keypad.png"))
        device.findObject(androidx.test.uiautomator.By.text("Settings")).click()
        assertNotNull(device.wait(androidx.test.uiautomator.Until.findObject(androidx.test.uiautomator.By.text("Your phone")),10000))
        device.findObject(androidx.test.uiautomator.By.res("android:id/button2")).click()
        assertNotNull(device.wait(androidx.test.uiautomator.Until.findObject(androidx.test.uiautomator.By.text("Disconnect this phone?")),10000))
        device.findObject(androidx.test.uiautomator.By.res("android:id/button1")).click()
        await("already-revoked local account cleared"){store.read()==null}
        assertNotNull(device.wait(androidx.test.uiautomator.Until.findObject(androidx.test.uiautomator.By.text("Scan QR code")),10000))
    }

}
