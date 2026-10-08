package com.openweb.pbx
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.MultiFormatReader
import com.google.zxing.MultiFormatWriter
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import org.json.JSONObject
import java.io.File
import android.graphics.BitmapFactory
import org.junit.Assume.assumeTrue
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
@RunWith(AndroidJUnit4::class)
class DeviceSecurityTest {
    @Test fun encryptedAccountRoundTripAndTamperRejection() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext;val store=PhoneStore(context)
        val old=store.read()
        try {
            val value=JSONObject().put("token","test-secret-not-for-publication").put("sip",JSONObject().put("password","generated-test-password"))
            store.save(value);assertEquals(value.toString(),store.read().toString())
            val prefs=context.getSharedPreferences("private_account",0);val sealed=prefs.getString("sealed",null)!!
            assertFalse(sealed.contains("test-secret"));assertFalse(sealed.contains("generated-test-password"))
            prefs.edit().putString("sealed",sealed.dropLast(5)+"AAAAA").commit();assertNull(store.read())
        }finally{if(old!=null)store.save(old)else store.clear()}
    }
    @Test fun nativeQrDecoderReadsEnrollmentJson() {
        val json="{\"type\":\"openwebpbx\",\"version\":1,\"server\":\"https://pbx.example.com\",\"code\":\"example-code-1234567890\"}"
        val matrix=MultiFormatWriter().encode(json,BarcodeFormat.QR_CODE,512,512)
        val pixels=IntArray(512*512){if(matrix[it%512,it/512])0xff000000.toInt()else 0xffffffff.toInt()}
        val result=MultiFormatReader().decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(512,512,pixels))))
        assertEquals(json,result.text);assertEquals("https://pbx.example.com",Enrollment.server(JSONObject(result.text).getString("server")))
    }
    @Test fun decodesThePbxGeneratedQrImage() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val file=File(context.getExternalFilesDir(null),"server-qr.png")
        assumeTrue("Supply the private PBX QR raster for this integration check",file.exists())
        val image=BitmapFactory.decodeFile(file.path)
        val pixels=IntArray(image.width*image.height);image.getPixels(pixels,0,image.width,0,0,image.width,image.height)
        val result=MultiFormatReader().decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(image.width,image.height,pixels))))
        val data=JSONObject(result.text)
        assertEquals("openwebpbx",data.getString("type"));assertEquals(1,data.getInt("version"))
        assertTrue(Enrollment.server(data.getString("server")).startsWith("https://"));assertTrue(Enrollment.code(data.getString("code")).length>=16)
    }

}
