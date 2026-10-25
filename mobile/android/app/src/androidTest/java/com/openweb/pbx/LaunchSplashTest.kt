package com.openweb.pbx

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.WindowManager
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.test.uiautomator.UiDevice
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
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
    private fun awaitVisible(activity:Activity,wanted:Boolean,timeout:Long=7_000){
        val until=SystemClock.elapsedRealtime()+timeout
        while(visible(activity)!=wanted && SystemClock.elapsedRealtime()<until)SystemClock.sleep(20)
        assertEquals("Native brand visibility",wanted,visible(activity))
    }
    @Test fun logoDisplaysForFiveSecondsWithoutRemovingScreenSecurity(){
        val activity=launch()
        try {
            awaitVisible(activity,true);val start=SystemClock.elapsedRealtime()
            inst.runOnMainSync{assertTrue(activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE!=0)}
            if(InstrumentationRegistry.getArguments().getString("splashCapture")=="true")inst.runOnMainSync{
                val view=activity.window.decorView;val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
                try{view.draw(Canvas(bitmap));context.getExternalFilesDir("splash-review")!!.resolve("native-splash-119.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}}finally{bitmap.recycle()}
            }
            SystemClock.sleep(4_300);assertTrue("Branding disappeared early",visible(activity))
            awaitVisible(activity,false)
            val elapsed=SystemClock.elapsedRealtime()-start
            assertTrue("Five-second branding did not finish within its bounded window: $elapsed",elapsed in 4_500..6_500)
        } finally {inst.runOnMainSync{activity.finish()}}
    }
    @Test fun recreationDoesNotRestartFiveSeconds(){
        var activity=launch()
        try {
            awaitVisible(activity,true);val start=SystemClock.elapsedRealtime();SystemClock.sleep(1_800)
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
        val activity=launch()
        try {
            awaitVisible(activity,true);val start=SystemClock.elapsedRealtime();SystemClock.sleep(1_000)
            UiDevice.getInstance(inst).pressHome();SystemClock.sleep(400)
            context.startActivity(Intent(context,MainActivity::class.java).setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            awaitVisible(activity,false)
            assertTrue("Returning from background restarted an existing splash",SystemClock.elapsedRealtime()-start<6_500)
        }finally{inst.runOnMainSync{activity.finish()}}
    }
}
