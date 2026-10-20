package com.openweb.pbx

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProfileUiTest {
    private val inst get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=inst.targetContext
    private fun views(root:View):List<View> = listOf(root)+if(root is ViewGroup)(0 until root.childCount).flatMap{views(root.getChildAt(it))} else emptyList()
    private fun click(activity:Activity,label:String){inst.runOnMainSync{val view=views(activity.window.decorView).filterIsInstance<Button>().firstOrNull{it.text.toString()==label} ?: error("Missing visible action: $label");view.requestRectangleOnScreen(android.graphics.Rect(0,0,view.width,view.height),true);assertTrue(view.performClick())};inst.waitForIdleSync()}
    private fun launch():MainActivity=inst.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) as MainActivity
    private fun isolated(block:()->Unit){val prefs=context.getSharedPreferences("private_account",0);val before=prefs.getString("sealed",null);try{prefs.edit().clear().commit();block()}finally{context.stopService(Intent(context,PhoneService::class.java));prefs.edit().clear().commit();if(before!=null)prefs.edit().putString("sealed",before).commit()}}
    private fun verifyLinks(activity:Activity){
        val opened=mutableListOf<String>()
        val monitor=object:Instrumentation.ActivityMonitor(){override fun onStartActivity(intent:Intent):Instrumentation.ActivityResult? {if(intent.action==Intent.ACTION_VIEW){opened.add(intent.dataString ?: "");return Instrumentation.ActivityResult(Activity.RESULT_CANCELED,null)};return null}}
        inst.addMonitor(monitor)
        try{for(label in listOf("Terms of use","Privacy policy","Delete account / request data deletion"))click(activity,label)}finally{inst.removeMonitor(monitor)}
        assertEquals(listOf("https://openwebpbx.com/terms","https://openwebpbx.com/privacy","https://openwebpbx.com/delete"),opened)
    }
    @Test fun onboardingHasDirectExternalPolicyLinksAndEveryConnectionChoice()=isolated{
        val activity=launch()
        try{inst.runOnMainSync{val labels=views(activity.window.decorView).filterIsInstance<TextView>().map{it.text.toString()};for(expected in listOf("Scan QR code","Sign in with an app password","Import a setup file","Enter a connection code instead"))assertTrue(expected,expected in labels)};verifyLinks(activity)}finally{inst.runOnMainSync{activity.finish()}}
    }
    @Test fun mandatoryTenantGateKeepsDirectPolicyLinksWithMultipleSavedAccounts()=isolated{
        val store=PhoneStore(context)
        for(name in listOf("Alpha","Beta"))store.add(JSONObject().put("server","https://${name.lowercase()}.example.invalid").put("device_id","device-$name").put("token","test-$name-"+"x".repeat(32)).put("profile_name",name).put("needs_login",true).put("account",JSONObject().put("extension","100").put("display_name","Test phone")).put("sip",JSONObject().put("domain","${name.lowercase()}.example.invalid")))
        val activity=launch()
        try{verifyLinks(activity);inst.runOnMainSync{val labels=views(activity.window.decorView).filterIsInstance<TextView>().map{it.text.toString()};assertTrue("Accounts" in labels);assertTrue("Confirm tenant address" in labels);assertFalse("Change app password" in labels)};assertEquals(2,store.profiles().size)}finally{inst.runOnMainSync{activity.finish()}}
    }
    @Test fun matchingEmailAttachmentOpensNativeConfirmationWithoutConnecting()=isolated{
        val intent=Intent(Intent.ACTION_VIEW).setClass(context,MainActivity::class.java).setDataAndType(android.net.Uri.parse("content://com.openweb.pbx.test.setup-fixture/valid"),"application/vnd.openwebpbx.config+json").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        val activity=inst.startActivitySync(intent) as MainActivity
        try{
            val device=androidx.test.uiautomator.UiDevice.getInstance(inst)
            assertTrue(device.wait(androidx.test.uiautomator.Until.hasObject(androidx.test.uiautomator.By.text("Add this phone account?")),3000))
            assertTrue(device.hasObject(androidx.test.uiautomator.By.textContains("alpha.openwebpbx.com")))
            assertTrue(PhoneStore(context).profiles().isEmpty())
            device.findObject(androidx.test.uiautomator.By.res("android:id/button2")).click()
            assertTrue(PhoneStore(context).profiles().isEmpty())
        }finally{inst.runOnMainSync{activity.finish()}}
    }
    @Test fun tamperedStoreShowsRecoveryAndPreservesOriginalCiphertext()=isolated{
        val prefs=context.getSharedPreferences("private_account",0);val bad="not-a-valid-sealed-account";prefs.edit().putString("sealed",bad).commit()
        val activity=launch()
        try{inst.runOnMainSync{val labels=views(activity.window.decorView).filterIsInstance<TextView>().map{it.text.toString()};assertTrue("Saved accounts could not be opened" in labels);assertTrue("Reset local accounts" in labels)};verifyLinks(activity);assertEquals(bad,prefs.getString("sealed",null))}finally{inst.runOnMainSync{activity.finish()}}
    }
    @Test fun mandatoryEntryDoesNotUseResponseSuggestedOriginsOrForwardSavedTokens()=isolated{
        val store=PhoneStore(context);val original="original-secret-"+"x".repeat(32)
        val id=store.add(JSONObject().put("server","https://installation.example.invalid").put("device_id","owned-recovery-device").put("token",original).put("needs_login",true).put("account",JSONObject().put("extension","100").put("server","https://alpha.example.invalid")).put("sip",JSONObject().put("domain","alpha.example.invalid")))
        val activity=launch()
        try{
            val device=androidx.test.uiautomator.UiDevice.getInstance(inst)
            assertTrue(device.wait(androidx.test.uiautomator.Until.hasObject(androidx.test.uiautomator.By.text("Confirm tenant address")),5000))
            // UIAutomator reports an empty field's hint as text on Android13.
            inst.runOnMainSync{val input=views(activity.window.decorView).filterIsInstance<android.widget.EditText>().first();assertEquals("",input.text.toString());assertTrue(input.isEnabled)}
            assertEquals("https://installation.example.invalid",store.read(id)!!.getString("server"));assertEquals(original,store.read(id)!!.getString("token"))
        }finally{inst.runOnMainSync{activity.finish()}}
    }
    @Test fun reviewLayoutsInBothThemes()=isolated{
        org.junit.Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("profileScreenshots")=="true")
        val prefs=PhonePreferences(context);val before=prefs.theme
        fun capture(activity:MainActivity,name:String){inst.runOnMainSync{val view=activity.window.decorView;val bitmap=android.graphics.Bitmap.createBitmap(view.width,view.height,android.graphics.Bitmap.Config.ARGB_8888);view.draw(android.graphics.Canvas(bitmap));java.io.File(context.getExternalFilesDir(null),"$name.png").outputStream().use{bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)};bitmap.recycle()}}
        try{for(theme in listOf("Light","Dark")){
            prefs.theme=theme;val activity=launch()
            try{Thread.sleep(500);capture(activity,"profiles-onboarding-${theme.lowercase()}");verifyLinks(activity);Thread.sleep(250);capture(activity,"profiles-policy-links-${theme.lowercase()}")}finally{inst.runOnMainSync{activity.finish()}}
        }}finally{prefs.theme=before}
    }

    @Test fun currentAccountListingCapture()=isolated{
        org.junit.Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("profileScreenshots")=="true")
        val prefs=PhonePreferences(context);val before=prefs.theme;prefs.theme="Light"
        val store=PhoneStore(context)
        for(name in listOf("Sample office","Second office"))store.add(JSONObject().put("server","https://example.invalid").put("device_id","listing-$name").put("token","fictional-"+name+"x".repeat(32)).put("profile_name",name).put("needs_login",true).put("account",JSONObject().put("extension",if(name=="Sample office")"100" else "200").put("display_name","Sample user")).put("sip",JSONObject().put("domain","example.invalid")))
        val activity=launch()
        try{
            val device=androidx.test.uiautomator.UiDevice.getInstance(inst)
            click(activity,"Settings");device.findObject(androidx.test.uiautomator.By.text("Accounts")).click()
            assertTrue(device.wait(androidx.test.uiautomator.Until.hasObject(androidx.test.uiautomator.By.text("Add an account")),5000))
            inst.runOnMainSync{activity.window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)}
            Thread.sleep(4500);assertTrue(device.takeScreenshot(java.io.File(context.getExternalFilesDir(null),"profiles-accounts-listing.png")))
            device.findObject(androidx.test.uiautomator.By.res("android:id/button2")).click()
        }finally{inst.runOnMainSync{activity.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE);activity.finish()};prefs.theme=before}
    }
}
