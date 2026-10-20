package com.openweb.pbx

import android.content.Context
import android.content.Intent
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

/** Uses only stable reflection/UI APIs, so this qualifier runs on the exact116 APK. */
@RunWith(AndroidJUnit4::class)
class LegacyTenantSeedTest {
    @Test fun enrollThePublished116BeforeReplacement(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("tenantOriginLegacyFixture")=="true")
        val instrument=InstrumentationRegistry.getInstrumentation();val context=instrument.targetContext
        assertEquals("1.0.16",context.packageManager.getPackageInfo(context.packageName,0).versionName)
        val files=context.getExternalFilesDir(null)!!;val setup=JSONObject(File(files,"tenant-origin-setup.json").readText())
        require(setup.getString("tenant_server")=="https://google-play-review.openwebpbx.com")
        val klass=Class.forName("com.openweb.pbx.PhoneStore");val store=klass.getConstructor(Context::class.java).newInstance(context)
        val read=klass.getMethod("read");assertNull("This qualifier requires an empty owned test phone",read.invoke(store))
        context.getSharedPreferences("phone_preferences",0).edit().putString("theme","Light").putString("startup_page","Contacts").commit()
        context.startActivity(Intent().setClassName(context.packageName,"com.openweb.pbx.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val device=UiDevice.getInstance(instrument)
        assertTrue(device.wait(Until.hasObject(By.text("Enter a connection code instead")),15000))
        device.findObject(By.text("Enter a connection code instead")).click()
        assertTrue(device.wait(Until.hasObject(By.clazz("android.widget.EditText")),5000))
        val input=device.findObjects(By.clazz("android.widget.EditText"));assertEquals(2,input.size)
        input[0].text=setup.getString("server");input[1].text=setup.getString("code")
        device.findObject(By.res("android:id/button1")).click()
        val end=System.currentTimeMillis()+60000
        var saved:JSONObject?=null
        while(System.currentTimeMillis()<end){saved=read.invoke(store) as? JSONObject;if(saved!=null)break;Thread.sleep(200)}
        requireNotNull(saved){"Legacy enrollment did not complete"}
        assertEquals("8100",saved.getJSONObject("account").getString("extension"))
        assertEquals(setup.getString("server"),saved.getString("server"))
        File(files,"tenant-origin-before.private.json").writeText(saved.toString())
        File(files,"tenant-origin-preferences.private.json").writeText(JSONObject(context.getSharedPreferences("phone_preferences",0).all).toString())
        File(files,"tenant-origin-legacy.safe.json").writeText(JSONObject().put("exact_published116",true).put("ordinary_ui_enrollment",true).put("legacy_canonical_origin",true).toString())
    }
}
