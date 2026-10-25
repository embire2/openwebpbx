package com.openweb.pbx

import android.app.Activity
import android.app.Instrumentation
import android.app.KeyguardManager
import android.content.Intent
import android.os.SystemClock
import android.os.PowerManager
import android.view.View
import android.view.WindowManager
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.test.uiautomator.UiDevice
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Run on a disposable, unenrolled app. Never clears or changes an existing phone account. */
@RunWith(AndroidJUnit4::class)
class LaunchSplashTest {
    private val inst get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=inst.targetContext
    private fun requireFixture(){
        require(InstrumentationRegistry.getArguments().getString("launchSplashFixture")=="true") {"Explicit disposable splash fixture required"}
        require(PhoneStore(context).profiles().isEmpty()) {"Use an unenrolled disposable app; existing accounts are preserved"}
    }
    private fun launch(launcher:Boolean=true):MainActivity {
        requireFixture()
        val intent=Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        if(launcher){intent.action=Intent.ACTION_MAIN;intent.addCategory(Intent.CATEGORY_LAUNCHER)}
        return inst.startActivitySync(intent) as MainActivity
    }
    private fun visible(activity:Activity):Boolean {var result=false;inst.runOnMainSync{result=activity.findViewById<View>(R.id.brand_splash)?.isShown==true};return result}
    private fun timing(activity:Activity):LaunchSplashState.Saved {
        var saved:LaunchSplashState.Saved?=null
        inst.runOnMainSync {
            val owner=MainActivity::class.java.getDeclaredField("branding").apply{isAccessible=true}.get(activity)
            val state=BrandSplash::class.java.getDeclaredField("state").apply{isAccessible=true}.get(owner) as LaunchSplashState
            saved=state.save()
        }
        return saved!!
    }
    private fun observation(activity:Activity):String {
        var window=""
        inst.runOnMainSync{window="focus=${activity.hasWindowFocus()},window=${activity.window.decorView.windowVisibility},destroyed=${activity.isDestroyed},finishing=${activity.isFinishing}"}
        return "$window,interactive=${context.getSystemService(PowerManager::class.java).isInteractive},keyguard=${context.getSystemService(KeyguardManager::class.java).isKeyguardLocked},elapsed=${SystemClock.elapsedRealtime()},timing=${timing(activity)}"
    }
    private fun firstFrame(activity:Activity):Long {
        val until=SystemClock.elapsedRealtime()+7_000
        while((timing(activity).waitingForFrame || !visible(activity)) && SystemClock.elapsedRealtime()<until)SystemClock.sleep(20)
        val value=timing(activity)
        assertFalse("The first native frame was not displayed: ${observation(activity)}",value.waitingForFrame)
        assertTrue("A real timed brand frame is required: ${observation(activity)}",value.deadlineMillis>0 && visible(activity))
        return value.deadlineMillis-LaunchSplashState.DURATION_MILLIS
    }
    private fun awaitVisible(activity:Activity,wanted:Boolean,timeout:Long=7_000){
        val until=SystemClock.elapsedRealtime()+timeout
        while(visible(activity)!=wanted && SystemClock.elapsedRealtime()<until)SystemClock.sleep(20)
        assertEquals("Native brand visibility: ${observation(activity)}",wanted,visible(activity))
    }
    @Test fun logoDisplaysForFiveSecondsWithoutRemovingScreenSecurity(){
        val activity=launch()
        try {
            awaitVisible(activity,true);val start=firstFrame(activity)
            inst.runOnMainSync{assertTrue(activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE!=0)}
            if(InstrumentationRegistry.getArguments().getString("splashCapture")=="true"){
                var bitmap:Bitmap?=null
                inst.runOnMainSync{val view=activity.window.decorView;bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888).also{view.draw(Canvas(it))}}
                // Encoding must not block the app's main-thread timeout or be
                // followed by another full4.3s sleep beyond the source deadline.
                try{context.getExternalFilesDir("splash-review")!!.resolve("native-splash-119.png").outputStream().use{bitmap!!.compress(Bitmap.CompressFormat.PNG,100,it)}}finally{bitmap!!.recycle()}
            }
            val early=start+4_300
            assertTrue("The image observer exceeded its early-check deadline",SystemClock.elapsedRealtime()<early)
            SystemClock.sleep((early-SystemClock.elapsedRealtime()).coerceAtLeast(0));assertTrue("Branding disappeared early: ${observation(activity)}",visible(activity))
            awaitVisible(activity,false)
            val elapsed=SystemClock.elapsedRealtime()-start
            assertTrue("Five-second branding did not finish within its bounded window: $elapsed",elapsed in 4_500..6_500)
        } finally {inst.runOnMainSync{activity.finish()}}
    }
    @Test fun recreationDoesNotRestartFiveSeconds(){
        var activity=launch()
        try {
            awaitVisible(activity,true);val start=firstFrame(activity);SystemClock.sleep((start+1_800-SystemClock.elapsedRealtime()).coerceAtLeast(0))
            val monitor=Instrumentation.ActivityMonitor(MainActivity::class.java.name,null,false);inst.addMonitor(monitor)
            try {inst.runOnMainSync{activity.recreate()};activity=monitor.waitForActivityWithTimeout(5_000) as? MainActivity ?: error("Recreated activity unavailable")}
            finally {inst.removeMonitor(monitor)}
            awaitVisible(activity,false)
            assertTrue("Recreation extended branding",SystemClock.elapsedRealtime()-start<6_500)
        } finally {inst.runOnMainSync{activity.finish()}}
    }
    @Test fun explicitCallOrInstallerEntryIsImmediate(){
        val activity=launch(false)
        try {assertFalse(visible(activity))}finally{inst.runOnMainSync{activity.finish()}}
    }
    @Test fun aCallEntryInterruptsAlreadyVisibleBranding(){
        val activity=launch()
        try {
            awaitVisible(activity,true)
            context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            awaitVisible(activity,false,1_000)
        }finally{inst.runOnMainSync{activity.finish()}}
    }
    @Test fun updateNotificationEntryBypassesBranding(){
        requireFixture()
        val activity=inst.startActivitySync(Intent(context,MainActivity::class.java).setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            .putExtra("show_updates",true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) as MainActivity
        try {assertFalse(visible(activity))}finally{inst.runOnMainSync{activity.finish()}}
    }
    @Test fun backgroundReturnKeepsItsExistingDeadline(){
        var activity=launch()
        try {
            awaitVisible(activity,true);val start=firstFrame(activity);SystemClock.sleep((start+1_000-SystemClock.elapsedRealtime()).coerceAtLeast(0))
            UiDevice.getInstance(inst).pressHome();SystemClock.sleep(400)
            // A user launcher action is allowed to foreground the task; a
            // background application-context start is a different Android API.
            UiDevice.getInstance(inst).executeShellCommand("am start -W -n ${context.packageName}/.MainActivity -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000")
            val until=SystemClock.elapsedRealtime()+7_000;var current:MainActivity?=null
            do {
                inst.runOnMainSync{current=ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().singleOrNull()}
                if(current==null)SystemClock.sleep(20)
            }while(current==null && SystemClock.elapsedRealtime()<until)
            activity=current ?: error("The user launcher action did not resume MainActivity")
            awaitVisible(activity,false)
            assertTrue("Returning from background restarted an existing splash",SystemClock.elapsedRealtime()-start<6_500)
        }finally{inst.runOnMainSync{activity.finish()}}
    }
}
