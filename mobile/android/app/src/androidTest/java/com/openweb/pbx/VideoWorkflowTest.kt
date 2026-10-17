/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.Manifest
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.view.TextureView
import android.view.WindowManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.linphone.core.Call
import org.linphone.core.MediaEncryption
import org.linphone.core.RegistrationState
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sin
import kotlin.math.PI

/** Opt-in isolated software-media qualification. No credentials or real camera pictures are bundled. */
@RunWith(AndroidJUnit4::class)
class VideoWorkflowTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext
    private val device get()=UiDevice.getInstance(instrumentation)
    private val dir get()=context.getExternalFilesDir(null)!!
    private val phone get()=PhoneService.instance!!
    private val results=JSONArray()
    private var stateObserver:org.linphone.core.CoreListener?=null
    private var serial=0
    private var trace:PrivateVideoTrace?=null
    private fun main(action:()->Unit)=instrumentation.runOnMainSync(action)
    private fun await(label:String,timeout:Long=60000,condition:()->Boolean){
        val end=System.currentTimeMillis()+timeout
        while(System.currentTimeMillis()<end){var ready=false;main{ready=condition()};if(ready)return;Thread.sleep(200)}
        var detail=""
        main{val p=PhoneService.instance;detail="${p?.status}; call=${p?.call?.state}; video=${p?.video?.enabled}; camera=${p?.video?.cameraOn}; frames=${p?.video?.decodedFrames}; response=${p?.call?.errorInfo?.protocolCode}"}
        fail("Timed out: $label ($detail)")
    }
    private fun record(name:String,data:JSONObject=JSONObject()){
        results.put(data.put("case",name).put("passed",true))
        File(dir,"video-results.json").writeText(JSONObject().put("version",BuildConfig.VERSION_NAME).put("software_source",true).put("physical_camera_qualified",false).put("checks",results).toString(2))
    }
    private fun phase(name:String,scenario:String?=null){
        if(name!="ready_for_upgrade")serial++
        val payload=JSONObject().put("phase",name).put("serial",serial)
        if(scenario!=null)payload.put("scenario",scenario)
        val file=File(dir,"video-phase.json");val temp=File(dir,"video-phase.tmp");temp.writeText(payload.toString());check(temp.renameTo(file))
    }
    private fun openVideo():VideoCallActivity=instrumentation.startActivitySync(Intent(context,VideoCallActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as VideoCallActivity
    private fun endCall(){main{phone.hangup()};await("call ended"){phone.call==null};Thread.sleep(1500)}
    private fun videoEarpieceProtection(){
        main{
            assertTrue(phone.video.enabled);assertFalse(phone.video.cameraOn)
            val call=phone.call!!
            val selected=PhoneService::class.java.getDeclaredField("call").apply{isAccessible=true}
            val field=PhoneService::class.java.getDeclaredField("proximity").apply{isAccessible=true}
            val original=field.get(phone)
            val sync=PhoneService::class.java.getDeclaredMethod("syncCallAudio").apply{isAccessible=true}
            val lock=object:ProximityWakeLock{override var isHeld=false;override fun acquire(){isHeld=true};override fun release(){isHeld=false}}
            val protection=CallProximity(object:ProximityPlatform{override fun isSupported()=true;override fun createLock()=lock})
            var route=org.linphone.core.AudioDevice.Type.Earpiece
            // Waydroid has no physical earpiece. Override only this getter in a
            // temporary selected-call view; all identity/state/video parameters
            // remain those of the actual answered call. No proxy reaches JNI.
            val device=java.lang.reflect.Proxy.newProxyInstance(org.linphone.core.AudioDevice::class.java.classLoader,arrayOf(org.linphone.core.AudioDevice::class.java)){_,method,_->
                check(method.name=="getType");route
            } as org.linphone.core.AudioDevice
            val view=java.lang.reflect.Proxy.newProxyInstance(Call::class.java.classLoader,arrayOf(Call::class.java)){_,method,args->
                if(method.name=="getOutputAudioDevice")device else method.invoke(call,*(args ?: emptyArray()))
            } as Call
            try{
                field.set(phone,protection);selected.set(phone,view)
                sync.invoke(phone);assertTrue("Video on earpiece retains cheek protection",lock.isHeld)
                route=org.linphone.core.AudioDevice.Type.Speaker;sync.invoke(phone);assertFalse("Speaker releases cheek protection",lock.isHeld)
                route=org.linphone.core.AudioDevice.Type.Bluetooth;sync.invoke(phone);assertFalse("Headset keeps screen available",lock.isHeld)
                route=org.linphone.core.AudioDevice.Type.Earpiece;sync.invoke(phone);assertTrue("Returning to earpiece restores protection",lock.isHeld)
            }finally{protection.close();selected.set(phone,call);field.set(phone,original);sync.invoke(phone)}
        }
        record("camera_off_video_earpiece_speaker_proximity_integration",JSONObject().put("simulated_routes",true).put("physical_sensor_qualified",false))
    }
    private fun screenshot(name:String){
        var active:android.app.Activity?=null
        main{active=androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).firstOrNull();active?.window?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)}
        try{Thread.sleep(350);assertTrue("Native screenshot captured",device.takeScreenshot(File(dir,"$name-${device.displayWidth}.png")))}finally{main{active?.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)}}
    }
    private fun videoProof(activity:VideoCallActivity,name:String){
        await("camera media ready"){phone.call?.state==Call.State.StreamsRunning && phone.video.cameraOn}
        val before=phone.video.decodedFrames
        // StaticImage's frame rate setter affects an existing source, not future
        // streams. Reapply after resume/re-INVITE creates its replacement source.
        main{phone.core!!.setStaticPictureFps(10f)}
        await("decoded bidirectional video and audio",90000){
            File(dir,"video-proof-state.json").writeText(JSONObject().put("decoded_frames",phone.video.decodedFrames-before).put("state",phone.call?.state?.toString() ?: "idle").put("video_direction",phone.call?.currentParams?.videoDirection?.toString() ?: "none").put("camera_enabled",phone.call?.isCameraEnabled==true).put("capture_enabled",phone.core?.isVideoCaptureEnabled==true).put("audio_up",phone.call?.audioStats?.uploadBandwidth ?: 0).put("audio_down",phone.call?.audioStats?.downloadBandwidth ?: 0).put("video_up",phone.call?.videoStats?.uploadBandwidth ?: 0).put("video_down",phone.call?.videoStats?.downloadBandwidth ?: 0).toString())
            phone.video.decodedFrames>=before+6 && phone.call?.let{
            it.videoStats?.downloadBandwidth?.let{n->n>0}==true && it.videoStats?.uploadBandwidth?.let{n->n>0}==true &&
                it.audioStats?.downloadBandwidth?.let{n->n>0}==true && it.audioStats?.uploadBandwidth?.let{n->n>0}==true
        }==true}
        var facts=JSONObject()
        main{
            val call=phone.call!!;val params=call.currentParams
            assertEquals(MediaEncryption.SRTP,params.mediaEncryption)
            assertEquals("VP8",params.usedVideoPayloadType?.mimeType?.uppercase())
            assertTrue("Audio received during video",call.audioStats!!.downloadBandwidth>0)
            assertTrue("Audio sent during video",call.audioStats!!.uploadBandwidth>0)
            assertTrue("Video sent",call.videoStats!!.uploadBandwidth>0)
            val field=VideoCallActivity::class.java.getDeclaredField("remote").apply{isAccessible=true}
            val bitmap=(field.get(activity) as TextureView).getBitmap(160,120)
            assertNotNull("Native texture contains decoded remote video",bitmap)
            val colors=mutableSetOf<Int>();for(y in 0 until bitmap!!.height step 7)for(x in 0 until bitmap.width step 7)colors.add(bitmap.getPixel(x,y) and 0x00ffffff)
            assertTrue("Remote video contains a real test picture",colors.size>4)
            facts=JSONObject().put("decoded_frames",phone.video.decodedFrames-before).put("texture_distinct_colors",colors.size).put("video_up_kbps",call.videoStats!!.uploadBandwidth.toDouble()).put("video_down_kbps",call.videoStats!!.downloadBandwidth.toDouble()).put("audio_down_kbps",call.audioStats!!.downloadBandwidth.toDouble()).put("video_codec","VP8").put("encryption","SRTP")
            bitmap.recycle()
        }
        main{activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)}
        try{device.takeScreenshot(File(dir,"$name.png"))}finally{main{activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)}}
        record(name,facts)
    }
    @org.junit.After fun releaseOwnedCall(){trace?.close();main{PhoneService.instance?.let{it.hangup();it.video.stopCamera();it.core?.useFiles=false;it.core?.playFile=null;it.core?.recordFile=null;stateObserver?.let{observer->it.core?.removeListener(observer)}}}}
    @Test fun enrollmentAndRegistrationWithoutCalls(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("videoSetupOnly")=="true")
        val fixture=JSONObject(File(dir,"video-fixture.json").readText());val enrollment=fixture.getJSONObject("enrollment")
        if(PhoneStore(context).read()==null){
            val response=PhoneApi(enrollment.getString("server")).json("enroll",JSONObject().put("code",enrollment.getString("code")).put("device_name","Isolated video software test").put("platform","android"))
            response.put("server",enrollment.getString("server"));PhoneStore(context).save(response)
        }
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName,Manifest.permission.RECORD_AUDIO)
        if(Build.VERSION.SDK_INT>=33)instrumentation.uiAutomation.grantRuntimePermission(context.packageName,Manifest.permission.POST_NOTIFICATIONS)
        if(Build.VERSION.SDK_INT>=31)instrumentation.uiAutomation.grantRuntimePermission(context.packageName,Manifest.permission.BLUETOOTH_CONNECT)
        instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        await("trusted TLS registration",120000){PhoneService.instance?.core?.defaultAccount?.state==RegistrationState.Ok}
        main{assertNull(phone.call);assertFalse(phone.core!!.isVideoCaptureEnabled);assertTrue(phone.core!!.videoPayloadTypes.any{it.mimeType.equals("VP8",true)})}
        record("registration_only_no_camera_no_call")
    }
    @Test fun videoEntryActionsAndCompactLayout(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("videoUiOnly")=="true")
        val fixture=JSONObject(File(dir,"video-fixture.json").readText())
        val destination=fixture.getString("destination")
        val home=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        await("registered phone for video entry actions"){PhoneService.instance?.core?.defaultAccount?.state==RegistrationState.Ok}
        main{
            val core=phone.core!!
            assertEquals(0,core.setVideoDevice(core.videoDevicesList.first{it.contains("StaticImage",true)}))
        }
        // Exercise the actual directory lookup and user-facing entry points.
        device.findObject(By.desc("Keypad")).click();device.waitForIdle()
        assertTrue("Keypad number field loaded",device.wait(Until.hasObject(By.desc("Number or extension")),7000))
        device.findObject(By.desc("Number or extension")).text=destination
        main{home.getSystemService(android.view.inputmethod.InputMethodManager::class.java).hideSoftInputFromWindow(home.window.decorView.windowToken,0)}
        device.waitForIdle()
        val launch=device.findObject(By.desc("Video"));assertNotNull(launch)
        assertTrue("Video action remains on-screen",launch.visibleBounds.bottom<device.displayHeight)
        screenshot("keypad-video")
        launch.click()
        await("keypad video action connected",90000){phone.call?.state==Call.State.StreamsRunning && phone.video.enabled && phone.video.cameraOn}
        assertNotNull(device.findObject(By.text("Camera off")));assertNotNull(device.findObject(By.text("End call")))
        await("UI remote picture decoded",30000){phone.video.decodedFrames>0}
        Thread.sleep(500)
        screenshot("connected-video")
        record("keypad_video_entry_connected")
        device.findObject(By.text("End call")).click();await("UI call ended"){phone.call==null}
        device.findObject(By.text("Back to phone")).click()
        if(!device.wait(Until.hasObject(By.desc("Contacts")),7000))device.dumpWindowHierarchy(File(dir,"video-ui-failure.xml"))
        assertNotNull("Returned to the phone navigation",device.findObject(By.desc("Contacts")))
        device.findObject(By.desc("Contacts")).click()
        val end=System.currentTimeMillis()+15000
        while(device.findObject(By.textContains("\n$destination"))==null && System.currentTimeMillis()<end)Thread.sleep(200)
        val contact=device.findObject(By.textContains("\n$destination"));assertNotNull("Company contact loaded",contact)
        val entry=contact.parent.findObject(By.text("Video"));assertNotNull("Company contact has Video action",entry)
        screenshot("directory-video")
        entry.click()
        await("company directory video action connected",90000){phone.call?.state==Call.State.StreamsRunning && phone.video.enabled && phone.video.cameraOn}
        assertTrue("Directory call controls rendered",device.wait(Until.hasObject(By.text("End call")),7000))
        assertTrue("End call remains visible",device.findObject(By.text("End call")).visibleBounds.bottom<device.displayHeight)
        record("directory_video_entry_connected")
        device.findObject(By.text("End call")).click();await("directory call ended"){phone.call==null}
        device.findObject(By.text("Back to phone")).click()
    }
    @Test fun consentCameraLifecycleAndBidirectionalNativeVideo(){
        assumeTrue(InstrumentationRegistry.getArguments().getString("videoFixture")=="true")
        val fixtureFile=File(dir,"video-fixture.json");val fixture=JSONObject(fixtureFile.readText());fixtureFile.delete()
        val enrollment=fixture.getJSONObject("enrollment")
        if(PhoneStore(context).read()==null){
            val response=PhoneApi(enrollment.getString("server")).json("enroll",JSONObject().put("code",enrollment.getString("code")).put("device_name","Isolated video software test").put("platform","android"))
            response.put("server",enrollment.getString("server"));PhoneStore(context).save(response)
        }
        val saved=PhoneStore(context).read()!!;val bootstrap=PhoneApi(saved.getString("server"),saved.getString("token")).json("bootstrap")
        check(saved.getJSONObject("sip").getString("domain").endsWith(".invalid"))
        trace=PrivateVideoTrace(File(dir,"video-transport.private.log"))
        val sipIdentity=saved.getJSONObject("sip").getString("username")
        record("isolated_process_identity",JSONObject().put("package",context.packageName).put("uid",android.os.Process.myUid()).put("extension",saved.getJSONObject("account").getString("extension")).put("sip_username_sha256",java.security.MessageDigest.getInstance("SHA-256").digest(sipIdentity.toByteArray()).joinToString(""){"%02x".format(it)}))
        PhoneStore(context).update{it.put("features",bootstrap.getJSONArray("features"))}
        for(permission in listOf(Manifest.permission.RECORD_AUDIO,Manifest.permission.POST_NOTIFICATIONS,Manifest.permission.BLUETOOTH_CONNECT)){
            if(permission==Manifest.permission.POST_NOTIFICATIONS && Build.VERSION.SDK_INT<33 || permission==Manifest.permission.BLUETOOTH_CONNECT && Build.VERSION.SDK_INT<31)continue
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName,permission)
        }
        val home=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        await("trusted TLS registration",120000){PhoneService.instance?.core?.defaultAccount?.state==RegistrationState.Ok}
        var freshRegistration=false
        val registrationObserver=object:org.linphone.core.CoreListenerStub(){override fun onAccountRegistrationStateChanged(core:org.linphone.core.Core,account:org.linphone.core.Account,state:RegistrationState,message:String){if(state==RegistrationState.Ok)freshRegistration=true}}
        main{phone.core!!.addListener(registrationObserver);phone.core!!.refreshRegisters()}
        await("fresh TLS registration",90000){freshRegistration};main{phone.core!!.removeListener(registrationObserver)}
        record("fresh_registration_response")
        val destination=fixture.optString("destination","1002")
        // The test never selects a real handset camera. Only instrumentation enables SDK StaticImage.
        val picture=File(context.filesDir,"video-test-pattern.jpg")
        val image=Bitmap.createBitmap(640,480,Bitmap.Config.ARGB_8888)
        for(y in 0 until 480)for(x in 0 until 640)image.setPixel(x,y,Color.rgb(x*255/640,y*255/480,if((x/40+y/40)%2==0)220 else 30))
        picture.outputStream().use{image.compress(Bitmap.CompressFormat.JPEG,95,it)};image.recycle()
        val tone=File(context.filesDir,"video-test-tone.wav")
        val count=8000*180;val wav=ByteBuffer.allocate(44+count*2).order(ByteOrder.LITTLE_ENDIAN)
        wav.put("RIFF".toByteArray()).putInt(36+count*2).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16).put("data".toByteArray()).putInt(count*2)
        for(i in 0 until count)wav.putShort((sin(2*PI*440*i/8000)*6000).toInt().toShort())
        tone.writeBytes(wav.array())
        // The SDK appends recordings. A new qualification must not reuse a
        // previous run's successfully decoded media as evidence.
        File(dir,"video-received-audio.wav").delete()
        main{
            val core=phone.core!!;if(InstrumentationRegistry.getArguments().getString("videoAes128Only")=="true")core.srtpCryptoSuites="AES_CM_128_HMAC_SHA1_80";core.useFiles=true;core.playFile=tone.path;core.recordFile=File(dir,"video-received-audio.wav").path;core.setStaticPicture(picture.path);core.setStaticPictureFps(10f)
            val events=JSONArray();File(dir,"video-call-events.json").writeText("[]")
            stateObserver=object:org.linphone.core.CoreListenerStub(){override fun onCallStateChanged(core:org.linphone.core.Core,call:Call,state:Call.State,message:String){
                if(state==Call.State.Released)return
                events.put(JSONObject().put("state",state.toString()).put("current_video",call.currentParams.isVideoEnabled).put("offered_video",call.remoteParams?.isVideoEnabled==true).put("camera",phone.video.cameraOn).put("consent_pending",phone.video.requestPending).put("response",call.errorInfo.protocolCode))
                File(dir,"video-call-events.json").writeText(events.toString(2))
            }}.also{core.addListener(it)}
            val static=core.videoDevicesList.firstOrNull{it.contains("StaticImage",true)} ?: error("Synthetic video source unavailable")
            assertEquals(0,core.setVideoDevice(static))
            assertFalse(core.videoActivationPolicy.automaticallyAccept);assertFalse(core.videoActivationPolicy.automaticallyInitiate)
            assertEquals(listOf("VP8"),core.videoPayloadTypes.filter{it.enabled()}.map{it.mimeType.uppercase()}.distinct())
            assertEquals("AES_CM_128_HMAC_SHA1_80",core.srtpCryptoSuites);assertTrue(core.isMediaEncryptionMandatory)
            try{phone.dial(destination,withVideo=true);fail("No visible video screen must refuse camera")}catch(_:IllegalStateException){}
            assertFalse(core.isVideoCaptureEnabled);assertNull(phone.call)
        };record("no_camera_without_visible_consent")
        var video=openVideo()
        if(context.checkSelfPermission(Manifest.permission.CAMERA)!=android.content.pm.PackageManager.PERMISSION_GRANTED){
            main{try{phone.dial(destination,withVideo=true);fail("Missing camera permission must refuse")}catch(_:IllegalStateException){};assertFalse(phone.core!!.isVideoCaptureEnabled);assertNull(phone.call)}
            record("camera_permission_denied_audio_available")
        }
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName,Manifest.permission.CAMERA)
        val features=PhoneStore(context).read()!!.getJSONArray("features")
        PhoneStore(context).update{it.put("features",JSONArray())}
        main{try{phone.dial(destination,withVideo=true);fail("Unsupported server must refuse video")}catch(_:IllegalStateException){};assertNull(phone.call);assertFalse(phone.core!!.isVideoCaptureEnabled)}
        PhoneStore(context).update{it.put("features",features)};record("legacy_server_audio_fallback")
        if(InstrumentationRegistry.getArguments().getString("videoInspectionOnly")=="true"){
            val finish=File(dir,"video-inspection-finish");finish.delete();phase("inspection_audio")
            main{phone.dial(destination)};await("inspection call answered"){phone.call?.state==Call.State.StreamsRunning};phase("inspection_connected")
            await("owned inspection released",150000){finish.exists()};finish.delete();endCall();phase("complete");main{video.finish();home.finish()};picture.delete();tone.delete();return
        }
        if(InstrumentationRegistry.getArguments().getString("videoPhoneServiceOnly")=="true"){
            phase("own_mailbox_audio")
            val received=File(dir,"video-own-mailbox.wav");received.delete()
            main{phone.core!!.recordFile=received.path;phone.dial("121")}
            await("own mailbox answered"){phone.call?.state==Call.State.StreamsRunning}
            Thread.sleep(10000)
            main{assertEquals(MediaEncryption.SRTP,phone.call!!.currentParams.mediaEncryption);assertFalse(phone.video.enabled);assertFalse(phone.video.cameraOn);assertFalse(phone.core!!.isVideoCaptureEnabled);assertTrue(phone.call!!.audioStats!!.downloadBandwidth>0)}
            record("own_121_mailbox_audio_camera_off_no_input");endCall();phase("complete");main{video.finish();home.finish()};picture.delete();tone.delete();return
        }
        if(InstrumentationRegistry.getArguments().getString("videoMixedPeerOnly")=="true"){
            phase("mixed_audio")
            main{phone.dial(fixture.optString("ordinary_destination","1003"))}
            await("ordinary phone answered"){phone.call?.state==Call.State.StreamsRunning}
            Thread.sleep(6000)
            main{assertEquals(MediaEncryption.SRTP,phone.call!!.currentParams.mediaEncryption);assertFalse(phone.video.enabled);assertFalse(phone.video.cameraOn);assertFalse(phone.core!!.isVideoCaptureEnabled);assertTrue(phone.call!!.audioStats!!.downloadBandwidth>0);assertTrue(phone.call!!.audioStats!!.uploadBandwidth>0);phone.hold()}
            await("ordinary phone hold"){phone.call?.state==Call.State.Paused};Thread.sleep(3000);main{phone.hold()}
            await("ordinary phone resume"){phone.call?.state==Call.State.StreamsRunning};Thread.sleep(8000)
            main{assertFalse(phone.video.enabled);assertFalse(phone.video.cameraOn);assertFalse(phone.core!!.isVideoCaptureEnabled);assertTrue(phone.call!!.audioStats!!.downloadBandwidth>0);assertTrue(phone.call!!.audioStats!!.uploadBandwidth>0)}
            record("ordinary_phone_audio_hold_resume_no_video");endCall();phase("complete");main{video.finish();home.finish()};picture.delete();tone.delete();return
        }
        if(InstrumentationRegistry.getArguments().getString("videoUpgradeOnly")!="true"){
        phase("outgoing_video")
        main{phone.dial(destination,withVideo=true)}
        await("outgoing video answered",90000){phone.call?.state==Call.State.StreamsRunning && phone.video.enabled}
        videoProof(video,"outgoing_video_decoded_texture_and_audio")
        Thread.sleep(15000) // Allow the independent PBX observer to bind both live legs.
        main{phone.video.stopCamera();phone.videoChanged();assertFalse(phone.video.cameraOn);assertFalse(phone.call!!.isCameraEnabled);assertFalse(phone.core!!.isVideoCaptureEnabled)}
        videoEarpieceProtection()
        Thread.sleep(2000);main{assertTrue(phone.call!!.audioStats!!.downloadBandwidth>0);phone.video.enable();assertTrue(phone.video.cameraOn)};record("camera_off_audio_continues_explicit_resume")
        device.pressHome();await("background closes capture"){!phone.video.cameraOn && !phone.core!!.isVideoCaptureEnabled}
        Thread.sleep(1500);main{assertEquals(Call.State.StreamsRunning,phone.call!!.state);assertTrue(phone.call!!.audioStats!!.downloadBandwidth>0)}
        video=openVideo();main{assertFalse(phone.video.cameraOn);phone.video.enable()};record("background_stops_camera_return_requires_action")
        device.sleep();await("screen lock stops capture"){!phone.core!!.isVideoCaptureEnabled};device.wakeUp();device.pressMenu();video=openVideo()
        main{assertFalse(phone.video.cameraOn);phone.video.enable();phone.mute();assertTrue(phone.muted);phone.mute();phone.dtmf('5');phone.hold()}
        await("video hold"){phone.call?.state==Call.State.Paused}
        main{
            assertFalse(phone.video.cameraOn)
            // Fault-inject the narrow first-stage recovery race into an actual
            // held call. A remote hold must cancel consent before any resume.
            val call=phone.call!!;val cls=CallVideo::class.java
            val restarting=cls.getDeclaredField("restartingCamera").apply{isAccessible=true}
            val restartOwner=cls.getDeclaredField("restartOwner").apply{isAccessible=true}
            val restartStage=cls.getDeclaredField("restartStage").apply{isAccessible=true}
            restarting.set(phone.video,call);restartOwner.set(phone.video,video);restartStage.setInt(phone.video,1)
            phone.video.state(call,Call.State.PausedByRemote)
            assertNull(restarting.get(phone.video));assertNull(restartOwner.get(phone.video));assertEquals(0,restartStage.getInt(phone.video));assertFalse(phone.core!!.isVideoCaptureEnabled)
            phone.hold()
        };record("pending_camera_restart_cancelled_by_remote_hold")
        await("video resume"){phone.call?.state==Call.State.StreamsRunning}
        Thread.sleep(1000) // A deliberate user action after the resume transaction settles.
        main{assertFalse(phone.video.cameraOn);phone.video.enable()};record("lock_hold_resume_preserve_explicit_camera_consent")
        videoProof(video,"resumed_video_and_audio")
        main{phone.video.audioOnly()};await("switch to audio"){phone.call?.state==Call.State.StreamsRunning && !phone.video.enabled};main{assertFalse(phone.core!!.isVideoCaptureEnabled)};record("switch_to_audio");endCall()
        for(withVideo in listOf(false,true)){
            phase(if(withVideo)"incoming_video_answer" else "incoming_audio_answer")
            await("incoming offered video",90000){phone.waitingCall?.remoteParams?.isVideoEnabled==true}
            main{assertFalse(phone.core!!.isVideoCaptureEnabled);assertFalse(phone.video.cameraOn)}
            if(!withVideo){
                val stale=instrumentation.startActivitySync(Intent(context,VideoCallActivity::class.java).putExtra("incoming_id","expired-owned-call").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as VideoCallActivity
                await("stale incoming screen refuses replacement call"){stale.isFinishing || stale.isDestroyed}
                main{assertEquals(Call.State.IncomingReceived,phone.waitingCall!!.state);assertFalse(phone.video.cameraOn)};record("expired_incoming_id_cannot_answer_another_call")
            }
            video=openVideo();assertNotNull(device.findObject(By.text("Answer audio")));assertNotNull(device.findObject(By.text("Answer video")))
            main{phone.answer(phone.waitingCall,withVideo=withVideo)};await("incoming answer"){phone.call?.state==Call.State.StreamsRunning}
            if(withVideo)videoProof(video,"incoming_video_explicit_answer")else{main{assertFalse(phone.video.enabled);assertFalse(phone.core!!.isVideoCaptureEnabled)};Thread.sleep(1500);main{assertTrue(phone.call!!.audioStats!!.downloadBandwidth>0)};record("incoming_video_audio_only_answer")}
            endCall()
        }
        }
        for(accept in listOf(false,true)){
            val scenario=if(accept)"remote_upgrade_accept" else "remote_upgrade_decline";phase(scenario)
            await("incoming audio for upgrade",90000){phone.waitingCall?.state==Call.State.IncomingReceived};main{assertFalse("Inactive video must remain an audio call",phone.video.offered(phone.waitingCall))};record("incoming_audio_ignores_inactive_video");video=openVideo();main{phone.answer()};await("audio answered"){phone.call?.state==Call.State.StreamsRunning}
            phase("ready_for_upgrade",scenario)
            await("remote video requires consent",60000){phone.video.requestPending}
            main{assertFalse(phone.video.cameraOn);assertFalse(phone.core!!.isVideoCaptureEnabled);phone.video.respond(accept)}
            await("upgrade response"){phone.call?.state==Call.State.StreamsRunning}
            if(accept)videoProof(video,"remote_upgrade_explicit_accept")else{Thread.sleep(1500);main{assertFalse(phone.video.enabled);assertFalse(phone.video.cameraOn);assertTrue("Audio continues after declining video",phone.call!!.audioStats!!.downloadBandwidth>0);assertTrue(phone.call!!.audioStats!!.uploadBandwidth>0)};record("remote_upgrade_declined_camera_stays_off")}
            endCall()
        }
        phase("complete");main{video.finish();home.finish()};picture.delete();tone.delete();record("selected_video_cases_complete")
    }
}
