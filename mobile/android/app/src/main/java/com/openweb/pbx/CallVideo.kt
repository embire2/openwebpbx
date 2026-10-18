/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.Manifest
import android.app.KeyguardManager
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import org.linphone.core.*

/** A camera is granted to one conversation by an explicit action, never by SIP. */
object VideoPrivacy {
    fun mayCapture(visible:Boolean,unlocked:Boolean,interactive:Boolean,permission:Boolean)=visible && unlocked && interactive && permission
    fun activeVideoOffer(enabled:Boolean,direction:MediaDirection?)=enabled && direction in listOf(MediaDirection.SendRecv,MediaDirection.SendOnly,MediaDirection.RecvOnly)
    fun cameraDevice(name:String)=!name.contains("StaticImage",true) && !name.contains("Mire",true)
}

class CallVideo(private val phone:PhoneService) {
    private val main=Handler(Looper.getMainLooper())
    private var owner:Any?=null
    private var cameraCall:Long?=null
    private var outgoingCamera=false
    private var pending:Call?=null
    private var receiveOnlyGraph:Long?=null
    private var restartingCamera:Call?=null
    private var restartOwner:Any?=null
    private var restartStage=0
    private var restartGeneration=0L
    private var closed=false
    var message="";private set
    var decodedFrames=0L;private set
    val cameraOn get()=cameraCall!=null && allowed()
    val requestPending get()=pending?.let{it.nativePointer==phone.call?.nativePointer}==true
    val enabled get()=phone.call?.currentParams?.isVideoEnabled==true
    val offered get()=offered(phone.call)
    fun offered(call:Call?)=call?.remoteParams?.let{VideoPrivacy.activeVideoOffer(it.isVideoEnabled,it.videoDirection)}==true
    private val core get()=phone.core ?: error("Your phone is not connected")
    private val listener=object:CallListenerStub() {
        override fun onNextVideoFrameDecoded(call:Call){
            decodedFrames++
            main.postDelayed({if(!closed && phone.calls.any{it.nativePointer==call.nativePointer} && call.currentParams.isVideoEnabled)call.requestNotifyNextVideoFrameDecoded()},200)
        }
        override fun onCameraNotWorking(call:Call,cameraName:String){stopCamera();message="The camera could not start. Your audio call can continue.";phone.videoChanged()}
    }
    private val screen=object:BroadcastReceiver(){override fun onReceive(context:Context,intent:Intent){if(intent.action==Intent.ACTION_SCREEN_OFF){stopCamera();phone.videoChanged()}}}
    init { phone.registerReceiver(screen,IntentFilter(Intent.ACTION_SCREEN_OFF)) }
    fun configure(c:Core) {
        c.videoActivationPolicy=c.videoActivationPolicy.apply{automaticallyInitiate=false;automaticallyAccept=false}
        c.isVideoCaptureEnabled=false;c.isVideoDisplayEnabled=true;c.isVideoPreviewEnabled=false
        // setVideoPayloadTypes only sorts; omitted codecs remain enabled in the SDK.
        c.videoPayloadTypes.forEach{it.enable(it.mimeType.equals("VP8",true))}
        c.setPreferredVideoDefinitionByName("vga")
        c.preferredFramerate=15f
    }
    fun visible(token:Any){owner=token}
    fun hidden(token:Any){if(owner===token){owner=null;stopCamera();detach();phone.videoChanged()}}
    private fun allowed()=VideoPrivacy.mayCapture(owner!=null,!phone.getSystemService(KeyguardManager::class.java).isDeviceLocked,phone.getSystemService(PowerManager::class.java).isInteractive,phone.checkSelfPermission(Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)
    private fun requireCapture() {
        check(allowed()){ "Open and unlock the video screen, then allow camera access." }
        check(phone.calls.size<=1 && phone.conference==null && !phone.conferenceOnHold){"Video is available in a call with one person."}
        check(core.videoPayloadTypes.any{it.mimeType.equals("VP8",true) && it.enabled() && it.isUsable}){ "Video is unavailable on this phone. Audio calls still work." }
    }
    private fun startCamera(target:Call?=null) {
        requireCapture()
        // Set the Android camera service type while the requesting screen is visible,
        // before opening the capture device. Failure leaves the camera disabled.
        phone.videoForeground(true)
        core.isVideoCaptureEnabled=true
        core.isVideoPreviewEnabled=true
        if(target!=null){cameraCall=target.nativePointer;target.isCameraEnabled=true}
        message=""
    }
    fun requireServerVideo(){
        val features=(phone.profileFor() ?: PhoneStore(phone).read())?.optJSONArray("features")
        check(features!=null && (0 until features.length()).any{features.optString(it)=="video_calls"}){"Your phone server has not enabled video calls yet. You can still make audio calls."}
    }
    fun prepareOutgoing(){requireServerVideo();startCamera();outgoingCamera=true}
    fun outgoingFailed(){outgoingCamera=false;stopCamera()}
    fun callCreated(call:Call,state:Call.State) {
        message=""
        call.addListener(listener)
        if(state==Call.State.OutgoingInit && outgoingCamera && allowed()){
            cameraCall=call.nativePointer;call.isCameraEnabled=true;outgoingCamera=false
        }else call.isCameraEnabled=false
    }
    fun state(call:Call,state:Call.State) {
        if(pending?.nativePointer==call.nativePointer && state!=Call.State.UpdatedByRemote){pending=null;message=""}
        if(state==Call.State.UpdatedByRemote && offered(call) && !call.currentParams.isVideoEnabled && call.deferUpdate()==0){
            pending=call
            if(phone.calls.size!=1 || phone.conference!=null || phone.conferenceOnHold)respond(false)
            else{
                message="The other person would like a video call."
                main.postDelayed({if(pending?.nativePointer==call.nativePointer)respond(false)},25000)
            }
        }
        if(state==Call.State.StreamsRunning){
            // A stream rebuilt while capture was off has no sending graph in
            // this SDK, even when its negotiated SDP still says SendRecv.
            if(call.currentParams.isVideoEnabled && !core.isVideoCaptureEnabled)receiveOnlyGraph=call.nativePointer
            if(restartingCamera?.nativePointer==call.nativePointer){
                val consent=restartOwner===owner && allowed() && phone.call?.nativePointer==call.nativePointer && phone.calls.size==1 && phone.conference==null && !phone.conferenceOnHold
                if(restartStage==2){
                    if(consent && core.isVideoCaptureEnabled && call.currentParams.videoDirection in listOf(MediaDirection.SendRecv,MediaDirection.SendOnly)){
                        receiveOnlyGraph=null;restartingCamera=null;restartOwner=null;restartStage=0;message=""
                    }else{stopCamera();message="The camera could not restart. Your audio call can continue."}
                }else if(restartStage==3){
                    // The previous SIP transaction must unwind before phase two.
                }else if(consent && call.currentParams.videoDirection in listOf(MediaDirection.RecvOnly,MediaDirection.Inactive)){
                    restartStage=3
                    val generation=restartGeneration
                    main.postDelayed({finishCameraRestart(call,generation,SystemClock.elapsedRealtime()+2000)},400)
                }else{stopCamera();message="Your camera is off. Choose Camera on to try again."}
                if(call.currentParams.isVideoEnabled)call.requestNotifyNextVideoFrameDecoded()
                phone.videoChanged();return
            }
            if(call.currentParams.isVideoEnabled)call.requestNotifyNextVideoFrameDecoded()
            else if(cameraCall==call.nativePointer){stopCamera();message="Video was not accepted. Your audio call can continue."}
            if(cameraCall!=call.nativePointer || !allowed()){
                call.isCameraEnabled=false
                if(cameraCall==call.nativePointer)stopCamera()
            }
        }
        if(state in listOf(Call.State.Pausing,Call.State.Paused,Call.State.PausedByRemote) && (cameraCall==call.nativePointer || restartingCamera?.nativePointer==call.nativePointer))stopCamera()
        if(state in listOf(Call.State.End,Call.State.Error,Call.State.Released)){
            if(receiveOnlyGraph==call.nativePointer)receiveOnlyGraph=null
            if(restartingCamera?.nativePointer==call.nativePointer){restartingCamera=null;restartOwner=null;restartStage=0}
            if(pending?.nativePointer==call.nativePointer)pending=null
            if(cameraCall==call.nativePointer)stopCamera()
            call.removeListener(listener)
        }
    }
    fun prepareAnswer(call:Call,video:Boolean){if(video){check(offered(call)){"This is an audio call."};startCamera(call)}else call.isCameraEnabled=false}
    private fun finishCameraRestart(target:Call,generation:Long,deadline:Long){
        if(generation!=restartGeneration || restartingCamera?.nativePointer!=target.nativePointer || restartStage!=3)return
        if(restartOwner!==owner || !allowed() || phone.call?.nativePointer!=target.nativePointer || phone.calls.size!=1 || phone.conference!=null || phone.conferenceOnHold){stopCamera();phone.videoChanged();return}
        if(target.state!=Call.State.StreamsRunning){
            if(SystemClock.elapsedRealtime()<deadline){main.postDelayed({finishCameraRestart(target,generation,deadline)},200);return}
            stopCamera();message="Your camera is off. Choose Camera on to try again.";phone.videoChanged();return
        }
        if(target.currentParams.videoDirection !in listOf(MediaDirection.RecvOnly,MediaDirection.Inactive)){
            stopCamera();message="Your camera is off. Choose Camera on to try again.";phone.videoChanged();return
        }
        try{
            restartStage=2
            startCamera(target)
            val params=core.createCallParams(target)!!.apply{isVideoEnabled=true;isCameraEnabled=true;videoDirection=MediaDirection.SendRecv;mediaEncryption=MediaEncryption.SRTP}
            check(target.update(params)==0)
        }catch(_:Exception){stopCamera();message="The camera could not restart. Your audio call can continue."}
        phone.videoChanged()
    }
    fun respond(video:Boolean) {
        val target=pending ?: return
        if(target.state!=Call.State.UpdatedByRemote || phone.calls.none{it.nativePointer==target.nativePointer}){pending=null;message="";phone.videoChanged();return}
        if(video)startCamera(target)
        val params=core.createCallParams(target)!!.apply{isVideoEnabled=video;isCameraEnabled=video;if(video)videoDirection=MediaDirection.SendRecv;mediaEncryption=MediaEncryption.SRTP}
        pending=null
        if(target.acceptUpdate(params)!=0){stopCamera();message="Video could not start. Your audio call can continue."}
        else message=if(video)"Starting video…" else "Continuing with audio."
        phone.videoChanged()
    }
    fun enable() {
        val target=phone.call ?: error("Start a call first.")
        check(target.state==Call.State.StreamsRunning){"Wait for your call to connect or resume it first."}
        if(requestPending){respond(true);return}
        if(!target.currentParams.isVideoEnabled)requireServerVideo()
        if(target.currentParams.isVideoEnabled && receiveOnlyGraph==target.nativePointer){
            requireCapture()
            // A real direction transition forces the missing sending graph to
            // rebuild. Keep capture off until this first transaction completes;
            // the same visible user's consent is checked again in state().
            val params=core.createCallParams(target)!!.apply{isVideoEnabled=true;isCameraEnabled=false;videoDirection=MediaDirection.RecvOnly;mediaEncryption=MediaEncryption.SRTP}
            restartingCamera=target;restartOwner=owner;restartStage=1
            val generation=++restartGeneration
            main.postDelayed({if(restartingCamera?.nativePointer==target.nativePointer && restartGeneration==generation){stopCamera();message="Your camera is off. Choose Camera on to try again.";phone.videoChanged()}},5000)
            if(target.update(params)!=0){restartingCamera=null;restartOwner=null;restartStage=0;error("The camera could not restart. Your audio call can continue.")}
            message="Starting camera…";phone.videoChanged();return
        }
        startCamera(target)
        if(!target.currentParams.isVideoEnabled){
            val params=core.createCallParams(target)!!.apply{isVideoEnabled=true;isCameraEnabled=true;videoDirection=MediaDirection.SendRecv;mediaEncryption=MediaEncryption.SRTP}
            if(target.update(params)!=0){stopCamera();error("Video could not start. Your audio call can continue.")}
            message="Requesting video…"
        }
        phone.videoChanged()
    }
    fun stopCamera() {
        restartGeneration++
        restartingCamera=null;restartOwner=null;restartStage=0
        outgoingCamera=false;cameraCall=null
        phone.calls.forEach{it.isCameraEnabled=false}
        phone.core?.let{it.isVideoPreviewEnabled=false;it.isVideoCaptureEnabled=false}
        if(!closed)phone.videoForeground(false)
    }
    fun audioOnly() {
        if(requestPending){respond(false);return}
        val target=phone.call ?: return
        stopCamera()
        val params=core.createCallParams(target)!!.apply{isVideoEnabled=false;isCameraEnabled=false;mediaEncryption=MediaEncryption.SRTP}
        check(target.update(params)==0){"Your camera is off. Please try switching to audio again."}
        message="Continuing with audio.";phone.videoChanged()
    }
    fun switchCamera() {
        requireCapture();check(cameraOn){"Turn your camera on first."}
        val devices=core.videoDevicesList.filter{VideoPrivacy.cameraDevice(it)}
        check(devices.size>1){"This phone has one available camera."}
        val current=devices.indexOf(core.videoDevice);check(core.setVideoDevice(devices[(current+1)%devices.size])==0){"Could not switch the camera."}
    }
    fun attach(remote:Any,preview:Any){phone.core?.let{it.nativeVideoWindowId=remote;it.nativePreviewWindowId=preview}}
    fun detach(){phone.core?.let{it.nativePreviewWindowId=null;it.nativeVideoWindowId=null}}
    fun close(){closed=true;owner=null;stopCamera();detach();main.removeCallbacksAndMessages(null);phone.unregisterReceiver(screen)}
}
