/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.Manifest
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.linphone.core.Call
import org.linphone.core.RegistrationState
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin

/** Private second-process media fixture, never a distributed app or background-camera claim. */
@RunWith(AndroidJUnit4::class)
class NativeVideoPeerTest {
    @Test fun controlledSyntheticPeer(){
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        assumeTrue(InstrumentationRegistry.getArguments().getString("nativeVideoPeer")=="true")
        check(context.packageName=="com.openweb.pbx.peer116") { "Requires an isolated private application ID" }
        val dir=context.getExternalFilesDir(null)!!
        val file=File(dir,"native-peer-fixture.json")
        val fixture=JSONObject(file.readText());file.delete()
        val enrollment=fixture.getJSONObject("enrollment")
        if(PhoneStore(context).read()==null){
            val response=PhoneApi(enrollment.getString("server")).json("enroll",JSONObject().put("code",enrollment.getString("code")).put("device_name","Private synthetic native video peer").put("platform","android"))
            response.put("server",enrollment.getString("server"));PhoneStore(context).save(response)
        }
        for(p in listOf(Manifest.permission.CAMERA,Manifest.permission.RECORD_AUDIO,Manifest.permission.POST_NOTIFICATIONS,Manifest.permission.BLUETOOTH_CONNECT)){
            if(p==Manifest.permission.POST_NOTIFICATIONS && Build.VERSION.SDK_INT<33 || p==Manifest.permission.BLUETOOTH_CONNECT && Build.VERSION.SDK_INT<31)continue
            // Grant these to the private fixture with adb before starting it.
            // A second UiAutomation owner would block the primary app's UI test.
            check(context.checkSelfPermission(p)==android.content.pm.PackageManager.PERMISSION_GRANTED)
        }
        val saved=PhoneStore(context).read()!!
        check(saved.getJSONObject("sip").getString("domain").endsWith(".invalid"))
        val trace=PrivateVideoTrace(File(dir,"peer-transport.private.log"))
        val bootstrap=PhoneApi(saved.getString("server"),saved.getString("token")).json("bootstrap")
        PhoneStore(context).update{it.put("features",bootstrap.getJSONArray("features"))}
        instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val deadline=System.currentTimeMillis()+90000
        while(PhoneService.instance?.core?.defaultAccount?.state!=RegistrationState.Ok){check(System.currentTimeMillis()<deadline){"Native peer registration timeout"};Thread.sleep(200)}
        val phone=PhoneService.instance!!
        val image=Bitmap.createBitmap(640,480,Bitmap.Config.ARGB_8888)
        for(y in 0 until 480)for(x in 0 until 640)image.setPixel(x,y,Color.rgb(if((x/40+y/40)%2==0)230 else 20,x*255/640,y*255/480))
        val picture=File(context.filesDir,"peer-synthetic.jpg");picture.outputStream().use{image.compress(Bitmap.CompressFormat.JPEG,95,it)};image.recycle()
        val tone=File(context.filesDir,"peer-tone.wav");val count=8000*900
        val wav=ByteBuffer.allocate(44+count*2).order(ByteOrder.LITTLE_ENDIAN)
        wav.put("RIFF".toByteArray()).putInt(36+count*2).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16).put("data".toByteArray()).putInt(count*2)
        for(i in 0 until count)wav.putShort((sin(2*PI*880*i/8000)*6000).toInt().toShort());tone.writeBytes(wav.array())
        val syntheticConsent=Any()
        instrumentation.runOnMainSync{
            val core=phone.core!!
            if(InstrumentationRegistry.getArguments().getString("videoAes128Only")=="true")core.srtpCryptoSuites="AES_CM_128_HMAC_SHA1_80"
            val events=org.json.JSONArray();File(dir,"native-peer-events.json").writeText("[]")
            core.addListener(object:org.linphone.core.CoreListenerStub(){override fun onCallStateChanged(core:org.linphone.core.Core,call:Call,state:Call.State,message:String){
                if(state==Call.State.Released)return
                events.put(JSONObject().put("state",state.toString()).put("response",call.errorInfo.protocolCode).put("reason",call.reason.toString()).put("video",call.currentParams.isVideoEnabled).put("remote_video",call.remoteParams?.isVideoEnabled==true))
                File(dir,"native-peer-events.json").writeText(events.toString(2))
            }})
            val received=File(dir,"native-peer-decoded.wav");received.delete()
            core.useFiles=true;core.playFile=tone.path;core.recordFile=received.path;core.setStaticPicture(picture.path)
            // The two isolated processes share one Android audio device; the
            // synthetic peer must not take focus away from the app under test.
            core.config.setBool("audio","android_disable_audio_focus_requests",true)
            check(core.setVideoDevice(core.videoDevicesList.first{it.contains("StaticImage",true)})==0)
            // Only this guarded test authorizes a software source without a second
            // visible activity. No real camera can be selected by this fixture.
            phone.video.visible(syntheticConsent)
        }
        var previous=-1L;var running=true;var resumeReadyAt=0L;val end=System.currentTimeMillis()+15*60*1000
        try{
            while(running && System.currentTimeMillis()<end){
                val commandFile=File(dir,"native-peer-command.json")
                val command=if(commandFile.exists())runCatching{JSONObject(commandFile.readText())}.getOrNull()else null
                var state=JSONObject()
                instrumentation.runOnMainSync{
                    check(phone.core!!.videoDevice?.contains("StaticImage",true)==true)
                    // The answering endpoint can report StreamsRunning before
                    // this endpoint has received its final SIP answer.
                    val commandReady=command?.optString("action")!="upgrade_video" || phone.call?.state==Call.State.StreamsRunning
                    if(command!=null && command.getLong("serial")!=previous && commandReady){
                        previous=command.getLong("serial")
                        when(command.getString("action")){
                            "dial_audio"->phone.dial(fixture.getString("destination"))
                            "dial_video"->phone.dial(fixture.getString("destination"),withVideo=true)
                            "upgrade_video"->phone.video.enable()
                            "hangup"->phone.hangup()
                            "stop"->running=false
                            else->error("Unknown private peer command")
                        }
                    }
                    phone.waitingCall?.let{phone.answer(it,withVideo=phone.video.offered(it))}
                    if(phone.video.requestPending)phone.video.respond(true)
                    if(phone.call?.state==Call.State.StreamsRunning && phone.video.enabled){
                        // Explicit fixture consent resumes only its software picture
                        // after remote hold. Public camera behavior is unchanged.
                        if(!phone.video.cameraOn){
                            if(resumeReadyAt==0L)resumeReadyAt=System.currentTimeMillis()+3000
                            if(System.currentTimeMillis()>=resumeReadyAt && context.getSystemService(android.os.PowerManager::class.java).isInteractive && !context.getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked){resumeReadyAt=System.currentTimeMillis()+3000;phone.video.enable()}
                        }else resumeReadyAt=0L
                        phone.core!!.setStaticPictureFps(10f)
                    }else resumeReadyAt=0L
                    val call=phone.call
                    state=JSONObject().put("registered",phone.core!!.defaultAccount?.state==RegistrationState.Ok).put("command_serial",previous).put("call_state",call?.state?.toString() ?: "idle").put("video",phone.video.enabled).put("video_direction",call?.currentParams?.videoDirection?.toString() ?: "none").put("camera_enabled",call?.isCameraEnabled==true).put("capture_enabled",phone.core?.isVideoCaptureEnabled==true).put("camera_is_synthetic",true).put("decoded_video_frames",phone.video.decodedFrames).put("audio_down_kbps",call?.audioStats?.downloadBandwidth ?: 0).put("video_up_kbps",call?.videoStats?.uploadBandwidth ?: 0).put("video_down_kbps",call?.videoStats?.downloadBandwidth ?: 0).put("encryption",call?.currentParams?.mediaEncryption?.toString() ?: "none")
                }
                val temp=File(dir,"native-peer-state.tmp");temp.writeText(state.toString());check(temp.renameTo(File(dir,"native-peer-state.json")))
                Thread.sleep(200)
            }
        }finally{
            instrumentation.runOnMainSync{phone.hangup();phone.video.hidden(syntheticConsent);phone.core?.useFiles=false;phone.core?.playFile=null;phone.core?.recordFile=null}
            trace.close();picture.delete();tone.delete()
        }
    }
}
