/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.linphone.core.Call
import org.linphone.core.MediaEncryption
import java.io.File

/** Only run against an explicitly supplied disposable PBX; never a customer account. */
@RunWith(AndroidJUnit4::class)
class CallAudioTest {
    private val instrument get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrument.targetContext
    private val files get()=context.getExternalFilesDir(null)!!
    private val audio get()=context.getSystemService(AudioManager::class.java)
    private var competingFocus:AudioFocusRequest?=null
    private fun main(block:()->Unit)=instrument.runOnMainSync(block)
    private fun waitFor(label:String,timeout:Long=45000,condition:()->Boolean) {
        val until=System.currentTimeMillis()+timeout
        while(System.currentTimeMillis()<until){var done=false;main{done=condition()};if(done)return;Thread.sleep(250)}
        fail(label)
    }
    private fun connect() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("audioFixture")=="true")
        if(PhoneStore(context).read()==null) {
            val setup=JSONObject(File(files,"audio-setup.json").readText())
            val server=setup.getString("server")
            val account=PhoneApi(server).json("enroll",JSONObject().put("code",setup.getString("code")).put("device_name","Disposable Android audio QA").put("platform","android")).put("server",server)
            PhoneStore(context).save(account);File(files,"audio-setup.json").delete()
        }
        main{context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}
        waitFor("Disposable phone did not register",90000){PhoneService.instance?.status=="Ready for calls"}
    }
    private fun assertMedia()=main {
        val call=PhoneService.instance!!.call!!
        assertEquals(Call.State.StreamsRunning,call.state)
        assertEquals(MediaEncryption.SRTP,call.currentParams.mediaEncryption)
        assertTrue("Incoming audio stopped",call.audioStats!!.downloadBandwidth>0)
        assertTrue("Outgoing audio stopped",call.audioStats!!.uploadBandwidth>0)
    }
    @After fun stop() {
        competingFocus?.let{audio.abandonAudioFocusRequest(it)}
        main{PhoneService.instance?.hangup()}
    }
    @Test fun audioFocusAndBackgroundCall() {
        connect();main{PhoneService.instance!!.dial("1001")}
        waitFor("Call was not answered"){PhoneService.instance?.call?.state==Call.State.StreamsRunning}
        val baseline=InstrumentationRegistry.getArguments().getString("baselineWithoutMedia")=="true"
        if(baseline) {
            assertEquals("Baseline unexpectedly has call audio mode",AudioManager.MODE_NORMAL,audio.mode)
            File(files,"audio-baseline.txt").writeText("Published 1.0.4 answered SRTP call without MODE_IN_COMMUNICATION.\n")
            return
        }
        waitFor("Call did not obtain Android communication audio mode"){audio.mode==AudioManager.MODE_IN_COMMUNICATION}
        Thread.sleep(12000);assertMedia()
        val device=UiDevice.getInstance(instrument);device.pressHome()
        Thread.sleep(12000);assertMedia()
        main{context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}
        Thread.sleep(1000)
        val focus=AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setOnAudioFocusChangeListener({}).build()
        competingFocus=focus
        assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED,audio.requestAudioFocus(focus))
        waitFor("Competing call audio did not put the PBX call on hold"){PhoneService.instance?.call?.state==Call.State.Paused}
        audio.abandonAudioFocusRequest(focus);competingFocus=null
        main{PhoneService.instance!!.hold()}
        waitFor("Call did not resume after releasing competing audio"){PhoneService.instance?.call?.state==Call.State.StreamsRunning && audio.mode==AudioManager.MODE_IN_COMMUNICATION}
        Thread.sleep(12000);assertMedia()
        main{PhoneService.instance!!.hangup()}
        waitFor("Call audio mode was not released"){PhoneService.instance?.call==null && audio.mode==AudioManager.MODE_NORMAL}
        File(files,"audio-focus-verified.txt").writeText("Communication audio mode, active SRTP media, background/return, competing audio hold/resume and audio release passed.\n")
    }
    @Test fun incomingCallUsesSdkAudioFocus() {
        connect();File(files,"incoming-ready.txt").writeText("ready")
        waitFor("Isolated incoming call not delivered",90000){PhoneService.instance?.call?.state==Call.State.IncomingReceived}
        main{assertTrue(PhoneService.instance!!.core!!.isNativeRingingEnabled);PhoneService.instance!!.answer()}
        waitFor("Incoming call audio did not connect"){PhoneService.instance?.call?.state==Call.State.StreamsRunning && audio.mode==AudioManager.MODE_IN_COMMUNICATION}
        Thread.sleep(12000);assertMedia()
        main{PhoneService.instance!!.hangup()}
        waitFor("Incoming call did not release audio mode"){PhoneService.instance?.call==null && audio.mode==AudioManager.MODE_NORMAL}
        File(files,"incoming-audio-verified.txt").writeText("Incoming call answered with SDK ringing and communication audio mode; SRTP media and normal-mode release passed.\n")
    }
}
