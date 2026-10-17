/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.Manifest
import android.app.KeyguardManager
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.*
import android.view.*
import android.widget.*
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import org.linphone.core.Call
import org.linphone.mediastream.video.capture.CaptureTextureView

/** Native decoded video and camera preview; camera consent is local to this screen. */
class VideoCallActivity:ComponentActivity() {
    private val main=Handler(Looper.getMainLooper())
    private lateinit var remote:TextureView
    private lateinit var preview:CaptureTextureView
    private lateinit var status:TextView
    private lateinit var cameraStatus:TextView
    private lateinit var controls:LinearLayout
    private var resumed=false
    private var pendingCamera:(()->Unit)?=null
    private var startOnResume=false
    private var layoutKey=""
    private val phone get()=PhoneService.instance
    private val tick=object:Runnable{override fun run(){render();if(resumed)main.postDelayed(this,300)}}
    private val permission=registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()){result->
        if(checkSelfPermission(Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED || checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){pendingCamera=null;toast("Allow camera and microphone access to share video. You can still answer with audio.")}
        else runPendingCamera()
    }
    private fun dp(n:Int)=(n*resources.displayMetrics.density).toInt()
    private fun line()=LinearLayout(this).apply{orientation=LinearLayout.HORIZONTAL;gravity=Gravity.CENTER}
    private fun button(label:String,action:()->Unit)=Button(this).apply{text=label;isAllCaps=false;minHeight=dp(48);textSize=13f;setOnClickListener{attempt(action)}}
    private fun row(vararg buttons:Button){val line=line();buttons.forEach{line.addView(it,LinearLayout.LayoutParams(0,dp(52),1f).apply{setMargins(dp(2),0,dp(2),0)})};controls.addView(line)}
    private fun attempt(action:()->Unit){try{action();render()}catch(e:Exception){toast(e.message ?: "Please try again. Your audio call remains available.")}}
    private fun toast(text:String)=Toast.makeText(this,text,Toast.LENGTH_LONG).show()
    override fun onCreate(state:Bundle?) {
        super.onCreate(state);window.addFlags(WindowManager.LayoutParams.FLAG_SECURE or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        startOnResume=state==null && intent.getBooleanExtra("start_video",false)
        val root=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(dp(12),dp(10),dp(12),dp(10));setBackgroundColor(0xff101b27.toInt())}
        root.setOnApplyWindowInsetsListener{view,insets->view.setPadding(dp(12),insets.systemWindowInsetTop+dp(8),dp(12),insets.systemWindowInsetBottom+dp(8));insets}
        val header=line();header.addView(button("Back to phone"){finish()},LinearLayout.LayoutParams(-2,dp(48)));status=TextView(this).apply{textSize=16f;setTextColor(Color.WHITE);gravity=Gravity.CENTER};header.addView(status,LinearLayout.LayoutParams(0,-2,1f));root.addView(header)
        val stage=FrameLayout(this).apply{setBackgroundColor(Color.BLACK)}
        remote=TextureView(this).apply{contentDescription="Other person's video"};stage.addView(remote,FrameLayout.LayoutParams(-1,-1))
        preview=CaptureTextureView(this).apply{contentDescription="Your camera preview"};stage.addView(preview,FrameLayout.LayoutParams(dp(100),dp(140),Gravity.TOP or Gravity.END).apply{setMargins(dp(8),dp(8),dp(8),dp(8))})
        root.addView(stage,LinearLayout.LayoutParams(-1,0,1f))
        cameraStatus=TextView(this).apply{textSize=14f;setTextColor(Color.WHITE);gravity=Gravity.CENTER;setPadding(0,dp(6),0,dp(6))};root.addView(cameraStatus)
        controls=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL};root.addView(controls)
        setContentView(root)
    }
    override fun onResume(){super.onResume();resumed=true
        val rotation=if(Build.VERSION.SDK_INT>=30)display?.rotation else windowManager.defaultDisplay.rotation
        phone?.core?.deviceRotation=when(rotation){Surface.ROTATION_90->90;Surface.ROTATION_180->180;Surface.ROTATION_270->270;else->0}
        preview.rotateToMatchDisplayOrientation()
        phone?.video?.visible(this);phone?.video?.attach(remote,preview);main.post(tick)
        if(startOnResume){startOnResume=false;cameraAction{phone?.dial(intent.getStringExtra("number") ?: "",withVideo=true) ?: error("Open the phone to reconnect first.")}}
        else runPendingCamera()
    }
    override fun onPause(){resumed=false;main.removeCallbacks(tick);phone?.video?.hidden(this);super.onPause()}
    override fun onDestroy(){pendingCamera=null;main.removeCallbacksAndMessages(null);super.onDestroy()}
    private fun cameraAction(action:()->Unit) {
        if(!resumed || getSystemService(KeyguardManager::class.java).isDeviceLocked){toast("Unlock your phone before turning on the camera.");return}
        val needed=listOf(Manifest.permission.CAMERA,Manifest.permission.RECORD_AUDIO).filter{checkSelfPermission(it)!=PackageManager.PERMISSION_GRANTED}
        if(needed.isEmpty()){attempt(action);return}
        pendingCamera=action;permission.launch(needed.toTypedArray())
    }
    private fun runPendingCamera(){
        if(!resumed)return
        val action=pendingCamera ?: return
        pendingCamera=null
        if(getSystemService(KeyguardManager::class.java).isDeviceLocked)return
        if(checkSelfPermission(Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED && checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)attempt(action)
    }
    private fun render() {
        val p=phone;val call=p?.call;val requestedIncoming=intent.getStringExtra("incoming_id")
        val incoming=if(requestedIncoming!=null)p?.incomingById(requestedIncoming) else call?.takeIf{it.state==Call.State.IncomingReceived}
        if(requestedIncoming!=null && incoming==null){finish();return}
        status.text=if(call==null)"Video call" else "${p.callLabel} · ${if(p.video.enabled)"Video" else "Audio"}"
        preview.visibility=if(p?.video?.cameraOn==true)View.VISIBLE else View.INVISIBLE
        cameraStatus.text=when{p==null->"Open the phone to reconnect.";incoming!=null->"Your camera is off until you choose Answer video.";p.video.requestPending->"Video requested · Choose video or keep audio.";p.video.cameraOn->"Camera on · ${p.video.message}";p.video.message.isNotEmpty()->"Camera off · ${p.video.message}";else->"Camera off · Audio continues when you leave this screen."}
        val key=listOf(call?.nativePointer,call?.state,incoming?.nativePointer,p?.video?.cameraOn,p?.video?.requestPending,p?.video?.enabled,p?.muted,p?.speaker,p?.canHold()).joinToString("|")
        if(key==layoutKey)return;layoutKey=key;controls.removeAllViews()
        if(p==null)return
        if(incoming!=null){
            row(button("Answer audio"){p.answer(incoming);intent.removeExtra("incoming_id")},button("Answer video"){cameraAction{p.answer(incoming,withVideo=true);intent.removeExtra("incoming_id")}}.apply{isEnabled=p.video.offered(incoming) && p.calls.size==1 && p.conference==null && !p.conferenceOnHold})
            row(button("Decline"){p.hangup(incoming)})
        }else if(call==null){
            val number=intent.getStringExtra("number")
            if(!number.isNullOrEmpty())row(button("Start video call"){cameraAction{p.dial(number,withVideo=true)}})
        }else{
            if(p.video.requestPending)row(button("Keep audio"){p.video.respond(false)},button("Accept video"){cameraAction{p.video.respond(true)}})
            else row(button(if(p.video.cameraOn)"Camera off" else "Camera on"){if(p.video.cameraOn){p.video.stopCamera();p.videoChanged()}else cameraAction{p.video.enable()}},button("Switch camera"){p.video.switchCamera()}.apply{isEnabled=p.video.cameraOn},button("Audio only"){p.video.audioOnly()}.apply{isEnabled=p.video.enabled && call.state==Call.State.StreamsRunning})
            row(button(if(p.muted)"Unmute" else "Mute"){p.mute()},button(if(call.state==Call.State.Paused)"Resume" else "Hold"){p.hold()}.apply{isEnabled=p.canHold()},button(if(p.speaker)"Earpiece" else "Speaker"){p.speaker()})
            row(button("End call"){p.hangup()}.apply{setTextColor(Color.WHITE);backgroundTintList=android.content.res.ColorStateList.valueOf(0xffac3045.toInt())})
        }
    }
}
