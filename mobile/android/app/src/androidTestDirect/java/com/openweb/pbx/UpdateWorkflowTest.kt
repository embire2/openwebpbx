/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
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
import java.io.File
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Explicit, private signed fixture only. No test URL/key/bypass exists in the shipped application. */
@RunWith(AndroidJUnit4::class)
class UpdateWorkflowTest {
    private val i get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=i.targetContext
    private val device get()=UiDevice.getInstance(i)
    private val fixture get()=File(context.getExternalFilesDir(null),"updates")
    private fun main(block:()->Unit)=i.runOnMainSync(block)
    private fun enabled(){assumeTrue(InstrumentationRegistry.getArguments().getString("updateFixture")=="true")}
    private fun waitFor(label:String,condition:()->Boolean){repeat(120){var ok=false;main{ok=condition()};if(ok)return;Thread.sleep(250)};fail(label)}
    private fun activity()=i.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
    private fun manager():UpdateManager {
        val transport=object:UpdateTransport{override fun open(url:String):InputStream=if(url==UpdateRules.FEED)File(fixture,"envelope.json").inputStream()else File(fixture,"candidate.apk").inputStream()}
        return UpdateManager(context,transport).also{UpdateManager::class.java.getDeclaredField("singleton").apply{isAccessible=true}.set(null,it)}
    }
    private fun check(m:UpdateManager,download:Boolean=false){val complete=CountDownLatch(1);m.check(download){complete.countDown()};assertTrue("Update check finished",complete.await(90,TimeUnit.SECONDS))}
    @Test fun enrollAndReviewNativeControls(){
        enabled()
        val setup=JSONObject(File(fixture,"setup.json").readText());val server=setup.getString("server")
        val account=PhoneStore(context).read() ?: PhoneApi(server).json("enroll",JSONObject().put("code",setup.getString("code")).put("device_name","Disposable Android updater QA").put("platform","android")).put("server",server)
        PhoneStore(context).save(account)
        val m=manager();val a=activity()
        waitFor("Native TLS phone connected"){PhoneService.instance?.status=="Ready for calls"}
        main{a.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)}
        assertEquals("1000",PhoneStore(context).read()!!.getJSONObject("account").getString("extension"))
        assertNotNull(device.wait(Until.findObject(By.textContains("1000")),5000))
        assertNotNull(device.findObject(By.desc("Call")));assertNotNull(device.findObject(By.desc("Contacts")))
        device.takeScreenshot(File(fixture,"native-keypad-104.png"))
        main{PhoneService.instance!!.dial("1001")}
        waitFor("Fixture call connected"){PhoneService.instance?.call?.state==org.linphone.core.Call.State.StreamsRunning}
        device.takeScreenshot(File(fixture,"native-call-104.png"))
        assertNotNull(device.findObject(By.desc("Mute")));assertNotNull(device.findObject(By.desc("Hold")));assertTrue(device.findObject(By.desc("Speaker"))!=null || device.findObject(By.desc("Earpiece"))!=null)
        main{PhoneService.instance!!.mute()};assertNotNull(device.wait(Until.findObject(By.desc("Unmute")),5000))
        main{PhoneService.instance!!.mute();PhoneService.instance!!.hangup()};waitFor("Call ended"){PhoneService.instance?.call==null}
        main{PhoneService.instance!!.dismissCallMessage()}
    }
    @Test fun redesignedCallControlsRemainFunctional(){
        enabled();val m=manager();val a=activity()
        waitFor("Phone connected"){PhoneService.instance?.status=="Ready for calls"}
        main{PhoneService.instance!!.dial("1001")};waitFor("Call connected"){PhoneService.instance?.call?.state==org.linphone.core.Call.State.StreamsRunning}
        assertNotNull(device.wait(Until.findObject(By.desc("Mute")),5000));device.findObject(By.desc("Mute")).click()
        assertNotNull(device.wait(Until.findObject(By.desc("Unmute")),5000));device.findObject(By.desc("Unmute")).click()
        main{PhoneService.instance!!.dtmf('5')};Thread.sleep(750)
        device.findObject(By.desc("Hold")).click();waitFor("On hold"){PhoneService.instance?.call?.state==org.linphone.core.Call.State.Paused}
        assertNotNull(device.wait(Until.findObject(By.desc("Resume")),5000));device.findObject(By.desc("Resume")).click()
        waitFor("Resumed"){PhoneService.instance?.call?.state==org.linphone.core.Call.State.StreamsRunning}
        Thread.sleep(12000)
        main{val c=PhoneService.instance!!.call!!;assertEquals(org.linphone.core.Call.State.StreamsRunning,c.state);assertTrue("Native received media",c.audioStats!!.downloadBandwidth>0);assertTrue("Native sent media",c.audioStats!!.uploadBandwidth>0)}
        device.findObject(By.desc("End call")).click();waitFor("Call ended"){PhoneService.instance?.call==null}
        File(fixture,"controls-verified.txt").writeText("Native vector controls: mute/unmute, hold/resume, DTMF and sustained two-way media passed.\n")
    }
    @Test fun selfDialConfirmationAndFailedCallRecovery(){
        enabled();val m=manager();val a=activity();waitFor("Phone ready"){PhoneService.instance?.status=="Ready for calls"}
        val field=device.wait(Until.findObject(By.desc("Number or extension")),5000);assertNotNull(field);field.text="1000"
        device.findObject(By.desc("Call")).click();assertNotNull(device.wait(Until.findObject(By.text("This is your own extension")),5000))
        assertNull(PhoneService.instance?.call);assertNotNull(device.wait(Until.findObject(By.res("android:id/button2")),5000));device.findObject(By.res("android:id/button2")).click()
        main{PhoneService.instance!!.dial("199999")}
        waitFor("Unknown extension failure reported"){PhoneService.instance?.call==null && PhoneService.instance?.lastCallMessage?.isNotEmpty()==true}
        assertNotNull(device.wait(Until.findObject(By.text("Call again")),5000));assertNotNull(device.findObject(By.text("Dismiss")))
        main{a.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)};device.takeScreenshot(File(fixture,"native-call-failure-104.png"))
        device.findObject(By.text("Dismiss")).click()
        waitFor("Failure message dismissed"){PhoneService.instance?.lastCallMessage==""}
    }
    @Test fun signedDownloadTamperFailureAndRequiredGate(){
        enabled();assertNotNull(PhoneStore(context).read())
        context.getSharedPreferences("application_updates",0).edit().clear().commit()
        File(context.filesDir,"application-updates").deleteRecursively()
        val m=manager();check(m);assertEquals("available",m.snapshot.state)
        assertFalse(File(context.filesDir,"application-updates/ready.apk").exists())
        assertFalse(m.shouldGate(false,false))
        check(m,true);assertEquals("ready",m.snapshot.state)
        val release=m.snapshot.release!!;val candidate=File(context.filesDir,"application-updates/ready.apk")
        assertEquals(release.bytes,candidate.length());m.verifyApk(candidate,release)
        val bad=JSONObject(release.envelope).put("signature","AAAA").toString()
        try{ReleaseManifest.parse(bad,context.assets.open("release-public.pem").bufferedReader().readText());fail("Bad signature accepted")}catch(_:Exception){}
        val tamper=File(context.cacheDir,"damaged-update.apk");candidate.copyTo(tamper,true)
        java.io.RandomAccessFile(tamper,"rw").use{it.seek(100);val old=it.read();it.seek(100);it.write(old xor 255)}
        try{m.verifyApk(tamper,release);fail("Tampered APK accepted")}catch(_:IllegalArgumentException){}finally{tamper.delete()}
        for((field,value) in listOf("mode" to "required","policyTrusted" to true,"checkSucceeded" to true))UpdateManager::class.java.getDeclaredField(field).apply{isAccessible=true}.set(m,value)
        assertTrue(m.shouldGate(false,false));assertFalse(m.shouldGate(true,false));assertFalse(m.shouldGate(false,true))
        val readyField=UpdateManager::class.java.getDeclaredField("ready").apply{isAccessible=true}
        readyField.set(m,release.copy(expires=System.currentTimeMillis()-1));assertFalse("Expired update cannot block calling",m.shouldGate(false,false));assertFalse(m.automaticInstallAllowed());readyField.set(m,release)
        UpdateManager::class.java.getDeclaredField("checkSucceeded").apply{isAccessible=true}.setBoolean(m,false);assertFalse(m.shouldGate(false,false))
        val prefs=context.getSharedPreferences("application_updates",0)
        prefs.edit().putLong("highest_sequence",release.sequence+1).putString("highest_digest","accepted-newer-release").commit()
        val offline=UpdateManager(context,object:UpdateTransport{override fun open(url:String):InputStream=throw java.io.IOException("Offline fixture")})
        check(offline);assertEquals("error",offline.snapshot.state);assertFalse("Stale cached APK removed after newer trusted metadata",candidate.exists());assertFalse(offline.shouldGate(false,false))
        prefs.edit().putLong("highest_sequence",release.sequence).putString("highest_digest",release.digest).commit()
        check(m,true);assertEquals("ready",m.snapshot.state)
        File(fixture,"download-verified.txt").writeText("Signed download, APK identity/hash/certificate, tamper refusal and safe required gate passed.\n")
    }
    @Test fun requiredPolicyWaitsForCallAndAllowsUrgentRecovery(){
        enabled();File(context.filesDir,"application-updates").deleteRecursively();val m=manager();val a=activity()
        waitFor("Phone connected"){PhoneService.instance?.status=="Ready for calls"}
        main{PhoneService.instance!!.dial("1001")};waitFor("Call active"){PhoneService.instance?.call?.state==org.linphone.core.Call.State.StreamsRunning}
        check(m);assertEquals("required",m.snapshot.mode);assertEquals("ready",m.snapshot.state)
        assertFalse(m.shouldGate(true,false));main{m.install(a)}
        main{assertEquals(org.linphone.core.Call.State.StreamsRunning,PhoneService.instance?.call?.state)}
        main{PhoneService.instance!!.hangup()};waitFor("Call ended"){PhoneService.instance?.call==null}
        assertNotNull(device.wait(Until.findObject(By.text("Your phone update is ready")),10000))
        main{a.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)};device.takeScreenshot(File(fixture,"required-update-recovery.png"))
        val urgent=device.findObject(By.text("Use phone for an urgent call"))
        if(urgent==null)device.swipe(180,510,180,220,15)
        assertNotNull(device.wait(Until.findObject(By.text("Use phone for an urgent call")),5000))
        device.findObject(By.text("Use phone for an urgent call")).click()
        assertNotNull(device.wait(Until.findObject(By.desc("Call")),5000))
        context.getSharedPreferences("application_updates",0).edit().putString("attempted_hash",m.snapshot.release!!.sha256).commit()
        main{m.install(a)}
        assertNotNull(device.wait(Until.findObject(By.text("Allow from this source")),10000))
        device.findObject(By.text("Allow from this source")).click();device.pressBack()
        waitFor("Android source permission granted"){context.packageManager.canRequestPackageInstalls()}
        // The required policy may now request its supported self-update path. Avoid installing in this test.
        main{m.cancelInstall()}
        File(fixture,"required-policy-verified.txt").writeText("Required policy downloads privately, defers active calls, exposes urgent access and uses Android source permission.\n")
    }
    @Test fun downloadPolicyStagesWithoutInstalling(){
        enabled();File(context.filesDir,"application-updates").deleteRecursively()
        val m=manager();check(m);assertEquals("download",m.snapshot.mode);assertEquals("ready",m.snapshot.state)
        assertTrue(File(context.filesDir,"application-updates/ready.apk").isFile);assertFalse(m.isInstalling);assertFalse(m.shouldGate(false,false))
    }
    @Test fun installationCancellationAndFailurePreserveAccount(){
        enabled();val before=PhoneStore(context).read()!!.getString("token")
        val m=manager();check(m,true);assertEquals("ready",m.snapshot.state);val a=activity();waitFor("Verified update ready after activity check"){m.snapshot.state=="ready" && !(UpdateManager::class.java.getDeclaredField("busy").apply{isAccessible=true}.get(m) as java.util.concurrent.atomic.AtomicBoolean).get()}
        main{m.install(a)}
        waitFor("Android confirmation requested"){m.snapshot.state=="confirmation"}
        assertNotNull(device.wait(Until.findObject(By.text("Cancel")),10000))
        device.takeScreenshot(File(fixture,"android-update-confirmation.png"))
        device.findObject(By.text("Cancel")).click()
        waitFor("Canceled session recovers"){!m.isInstalling}
        assertEquals(before,PhoneStore(context).read()!!.getString("token"));assertEquals(104L,context.packageManager.getPackageInfo(context.packageName,0).longVersionCode)
        // A forged/stale callback must not change an unrelated update session.
        main{m.installResult(Intent().setData(Uri.parse("openwebpbx-update://session/0/invalid")).putExtra(PackageInstaller.EXTRA_SESSION_ID,0).putExtra(PackageInstaller.EXTRA_STATUS,PackageInstaller.STATUS_SUCCESS))}
        assertEquals("ready",m.snapshot.state)
        // Exercise a valid non-success session result without modifying an installed APK.
        val prefs=context.getSharedPreferences("application_updates",0);prefs.edit().putInt("session_id",123).putString("nonce","test-failure").putLong("target_version",105).commit()
        main{m.installResult(Intent().setData(Uri.parse("openwebpbx-update://session/123/test-failure")).putExtra(PackageInstaller.EXTRA_SESSION_ID,123).putExtra(PackageInstaller.EXTRA_STATUS,PackageInstaller.STATUS_FAILURE_STORAGE))}
        assertFalse(m.isInstalling);assertEquals(before,PhoneStore(context).read()!!.getString("token"))
        File(fixture,"cancel-failure-verified.txt").writeText("Real Android confirmation/cancel and session failure preserve account.\n")
    }
    @Test fun launchVerifiedReplacement(){
        enabled();val m=manager()
        // Pinpoint a bad private fixture before the production updater deliberately
        // converts operational errors into a safe, credential-free user message.
        val account=PhoneStore(context).read()!!
        val policy=PhoneApi(account.getString("server"),account.getString("token")).json("updates")
        assertEquals(1,policy.getInt("schema"));assertEquals(UpdateRules.FEED,policy.getString("feed_url"))
        ReleaseManifest.parse(File(fixture,"envelope.json").readText(),context.assets.open("release-public.pem").bufferedReader().use{it.readText()})
        assertTrue("Private candidate APK is readable",File(fixture,"candidate.apk").canRead())
        check(m,true);assertEquals("ready",m.snapshot.state)
        File(fixture,"account-before.sha256").writeText(UpdateRules.sha256(PhoneStore(context).read()!!.getString("token").toByteArray()))
        val a=activity();waitFor("Verified update ready after activity check"){m.snapshot.state=="ready" && !(UpdateManager::class.java.getDeclaredField("busy").apply{isAccessible=true}.get(m) as java.util.concurrent.atomic.AtomicBoolean).get()};main{m.install(a)}
        waitFor("Android confirmation requested"){m.snapshot.state=="confirmation"}
        assertNotNull(device.wait(Until.findObject(By.text("Update")),10000))
        File(fixture,"installation-started.txt").writeText("Verified private replacement is awaiting native Android confirmation.\n")
        // External driver presses Update; Android replaces this test process as expected.
    }
    @Test fun verifyInstalledAccountAndRelaunch(){
        enabled()
        val expectedCode=InstrumentationRegistry.getArguments().getString("targetVersionCode")?.toLong() ?: 105L
        val expectedName=InstrumentationRegistry.getArguments().getString("targetVersionName") ?: "1.0.5"
        assertEquals(expectedCode,context.packageManager.getPackageInfo(context.packageName,0).longVersionCode)
        assertEquals(File(fixture,"account-before.sha256").readText(),UpdateRules.sha256(PhoneStore(context).read()!!.getString("token").toByteArray()))
        assertEquals("Installation completion was recorded",expectedCode,context.getSharedPreferences("application_updates",0).getLong("last_installed",0))
        // A subsequent policy check may refresh the notification before the user
        // opens it. In private-release tests the public feed may also be older.
        val note=context.getSystemService(android.app.NotificationManager::class.java).activeNotifications.single{it.id==UpdateManager.NOTIFICATION}
        val title=note.notification.extras.getString(android.app.Notification.EXTRA_TITLE)!!
        device.openNotification();assertNotNull(device.wait(Until.findObject(By.text(title)),10000));device.findObject(By.text(title)).click()
        waitFor("Updated phone reconnects"){PhoneService.instance?.status=="Ready for calls"}
        assertEquals("1000",PhoneStore(context).read()!!.getJSONObject("account").getString("extension"))
        if(device.hasObject(By.res("android:id/button2")))device.findObject(By.res("android:id/button2")).click() // Close the update details opened by its notification.
        assertNotNull(device.wait(Until.findObject(By.textContains("1000")),5000))
        File(fixture,"replacement-verified.txt").writeText("Native PackageInstaller replacement to $expectedName succeeded; account preserved and phone reconnected.\n")
    }
}
