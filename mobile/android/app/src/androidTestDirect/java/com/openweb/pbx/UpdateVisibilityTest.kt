/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import java.io.File
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean

/** Display-only fixtures: no account, network, APK download or installation. */
@RunWith(AndroidJUnit4::class)
class UpdateVisibilityTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext
    private val device get()=UiDevice.getInstance(instrumentation)
    private fun main(block:()->Unit)=instrumentation.runOnMainSync(block)
    /** Opt-in: host supplies a disposable registered account and answering internal 1001. */
    @Test fun enrolledUpdateCardAndActiveCallLayout(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("updateLayout")=="true")
        assumeTrue("An isolated enrolled phone is required",PhoneStore(context).read()!=null)
        val singleton=UpdateManager::class.java.getDeclaredField("singleton").apply{isAccessible=true}
        val previous=singleton.get(null)
        val manager=UpdateManager(context,object:UpdateTransport{override fun open(url:String):InputStream=throw IOException("Display-only fixture")})
        (UpdateManager::class.java.getDeclaredField("busy").apply{isAccessible=true}.get(manager) as AtomicBoolean).set(true)
        singleton.set(null,manager)
        var activity:MainActivity?=null
        fun display(){main{
            UpdateManager::class.java.getDeclaredField("snapshot").apply{isAccessible=true}.set(manager,UpdateSnapshot(state="downloading",mode="required",progress=10L*1048576,total=40L*1048576,displayVersion="9.9.9",releaseKey="display-fixture"))
            manager.changed?.invoke()
        }}
        fun capture(label:String,required:List<String>){main{
            val a=activity!!;val decor=a.window.decorView
            assertTrue("Secure window remains enabled",a.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE!=0)
            fun find(v:View,name:String):View?{if(v.contentDescription?.toString()==name)return v;if(v is ViewGroup)for(i in 0 until v.childCount){val match=find(v.getChildAt(i),name);if(match!=null)return match};return null}
            val bitmap=Bitmap.createBitmap(decor.width,decor.height,Bitmap.Config.ARGB_8888);decor.draw(Canvas(bitmap))
            File(context.filesDir,"update-layout-${a.resources.configuration.screenWidthDp}-$label.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)};bitmap.recycle()
            for(name in required){val v=find(decor,name);assertNotNull("Control exists: $name",v);val visible=Rect();assertTrue("Control visible: $name",v!!.getGlobalVisibleRect(visible));assertEquals("Control not clipped vertically: $name",v.height,visible.height());assertEquals("Control not clipped horizontally: $name",v.width,visible.width())}
        }}
        try{
            display();activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            assertNotNull(device.wait(Until.findObject(By.textContains("10.0 of 40.0 MB")),10000))
            assertNotNull(device.wait(Until.findObject(By.desc("Call")),10000));capture("idle",listOf("Call","Delete digit","Keypad","Contacts","Recents","Voicemail","1","2","3","4","5","6","7","8","9","*","0","#"))
            val deadline=System.currentTimeMillis()+20000
            while(PhoneService.instance?.status!="Ready for calls"&&System.currentTimeMillis()<deadline)Thread.sleep(100)
            main{assertEquals("Ready for calls",PhoneService.instance?.status);PhoneService.instance!!.dial("1001")}
            assertNotNull(device.wait(Until.findObject(By.desc("End call")),15000))
            assertNotNull(device.wait(Until.findObject(By.text("Required update · After your call")),5000))
            capture("call",listOf("End call","Mute","Hold",if(PhoneService.instance?.speaker==true)"Earpiece" else "Speaker","Keypad","Contacts","Recents","Voicemail","1","2","3","4","5","6","7","8","9","*","0","#"))
            assertFalse("No update dialog during a call",device.hasObject(By.res("android:id/button1")))
            main{PhoneService.instance?.hangup()}
            assertNotNull(device.wait(Until.findObject(By.desc("Call")),10000))
        }finally{main{PhoneService.instance?.hangup();activity?.finish()};context.getSystemService(android.app.job.JobScheduler::class.java).cancel(UpdateManager.JOB);singleton.set(null,previous)}
    }
    @Test fun prominentUpdateProgressAndNotificationEntry(){
        assumeTrue("Use a disposable account-free installation",PhoneStore(context).read()==null)
        val previous=UpdateManager::class.java.getDeclaredField("singleton").apply{isAccessible=true}.get(null)
        val manager=UpdateManager(context,object:UpdateTransport{override fun open(url:String):InputStream=throw IOException("Display-only fixture")})
        (UpdateManager::class.java.getDeclaredField("busy").apply{isAccessible=true}.get(manager) as AtomicBoolean).set(true)
        UpdateManager::class.java.getDeclaredField("singleton").apply{isAccessible=true}.set(null,manager)
        fun display(stage:String,progress:Long=0,total:Long=0){
            main{
                UpdateManager::class.java.getDeclaredField("snapshot").apply{isAccessible=true}.set(manager,UpdateSnapshot(state=stage,mode="required",progress=progress,total=total,displayVersion="9.9.9",releaseKey="display-fixture"))
                manager.changed?.invoke()
            }
        }
        var activity:MainActivity?=null
        try{
            display("available")
            activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            assertNotNull(device.wait(Until.findObject(By.text("Required update 9.9.9")),5000))
            assertTrue(device.findObject(By.res("android:id/button1")).text.equals("Download update",ignoreCase=true))
            display("downloading",10L*1048576,40L*1048576)
            assertNotNull(device.wait(Until.findObject(By.textContains("10.0 of 40.0 MB · 25%")),5000))
            assertFalse(device.findObject(By.res("android:id/button1")).isEnabled)
            display("verifying",40L*1048576,40L*1048576)
            assertNotNull(device.wait(Until.findObject(By.text("Checking the complete download")),5000))
            assertFalse(device.findObject(By.res("android:id/button1")).isEnabled)
            display("ready")
            assertNotNull(device.wait(Until.findObject(By.text("Required update ready 9.9.9")),5000))
            assertTrue(device.findObject(By.res("android:id/button1")).text.equals("Install update",ignoreCase=true))
            assertTrue(device.findObject(By.res("android:id/button1")).isEnabled)
            device.findObject(By.res("android:id/button2")).click()
            assertNotNull(device.wait(Until.findObject(By.text("Install update")),5000)) // Persistent home card.
            main{context.startActivity(Intent(context,MainActivity::class.java).putExtra("show_updates",true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))}
            assertNotNull(device.wait(Until.findObject(By.res("android:id/button1")),5000))
            assertTrue(device.findObject(By.res("android:id/button1")).text.equals("Install update",ignoreCase=true))
        }finally{
            main{activity?.finish()}
            context.getSystemService(android.app.job.JobScheduler::class.java).cancel(UpdateManager.JOB)
            UpdateManager::class.java.getDeclaredField("singleton").apply{isAccessible=true}.set(null,previous)
        }
    }
}
