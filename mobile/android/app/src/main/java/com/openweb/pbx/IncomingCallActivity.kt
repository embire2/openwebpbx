/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.*
import android.view.*
import android.widget.*
import org.json.JSONObject
import org.linphone.core.Call
import java.util.concurrent.Executors

/** Private notification destination. A stale notification can never answer a newer call. */
class IncomingCallActivity:Activity(){
    private val main=Handler(Looper.getMainLooper())
    private val worker=Executors.newSingleThreadExecutor()
    private lateinit var label:TextView
    private var verifiedCall:String?=null
    private var accepting=false
    private var checking=false
    private var declining=false
    private var request=""
    private var expiresAt=Long.MAX_VALUE
    private var openedAt=0L
    private val tick=object:Runnable{override fun run(){refresh();main.postDelayed(this,500)}}
    override fun onCreate(state:Bundle?){
        super.onCreate(state);setShowWhenLocked(true);setTurnScreenOn(true);window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        request=intent.getStringExtra("push_request") ?: ""
        openedAt=SystemClock.elapsedRealtime()
        val root=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;gravity=Gravity.CENTER;setPadding(32,48,32,48);setBackgroundColor(0xff142e39.toInt())}
        label=TextView(this).apply{text="Incoming call";textSize=28f;setTextColor(0xffffffff.toInt());gravity=Gravity.CENTER};root.addView(label)
        root.addView(Button(this).apply{text="Answer";minHeight=64;setOnClickListener{accepting=true;refresh()}})
        root.addView(Button(this).apply{text="Decline";minHeight=64;setOnClickListener{decline()}})
        setContentView(root)
        accepting=intent.getBooleanExtra("answer",false)
        declining=intent.getBooleanExtra("decline",false)
    }
    override fun onResume(){super.onResume();main.post(tick)}
    override fun onPause(){main.removeCallbacks(tick);super.onPause()}
    override fun onDestroy(){worker.shutdown();super.onDestroy()}
    private fun refresh(){
        val phone=PhoneService.instance
        if(request.isNotEmpty()){
            if(System.currentTimeMillis()>=expiresAt || SystemClock.elapsedRealtime()-openedAt>60000){PushConnection.cancel(this,request);finish();return}
            if(!checking){checking=true;worker.execute{
                try{val a=PhoneStore(this).read() ?: error("Disconnected");val response=PhoneApi(a.getString("server"),a.getString("token"),5000).json("push_call",id=request)
                    main.post{if(!isFinishing){if(!response.getBoolean("ringing")){PushConnection.cancel(this,request);finish()}else{verifiedCall=response.getString("call_id");expiresAt=try{java.time.OffsetDateTime.parse(response.getString("expires_at").replace(" ","T")).toInstant().toEpochMilli()}catch(_:Exception){System.currentTimeMillis()+60000};checking=false;if(declining)decline()}}}
                }catch(e:Exception){main.post{if(!isFinishing){if(e is ApiError&&e.status in listOf(400,401,403,404,410,422)){PushConnection.cancel(this,request);finish()}else{label.text="Could not reach your phone server. Tap Answer to retry.";checking=false}}}}
            }}
            if(!declining && phone==null && verifiedCall!=null && PhoneStore(this).read()!=null){try{startForegroundService(Intent(this,PhoneService::class.java))}catch(_:Exception){label.text="Open the app to reconnect"}}
        }
        val incoming=if(request.isEmpty())phone?.incomingById(intent.getStringExtra("call_id") ?: "")else phone?.calls?.firstOrNull{it.remoteParams?.getCustomHeader("X-OpenWeb-Push-ID")==verifiedCall && it.state==Call.State.IncomingReceived}
        if(request.isEmpty() && incoming==null){finish();return}
        if(accepting && incoming!=null){
            if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){startActivity(Intent(this,MainActivity::class.java));finish();return}
            try{phone?.answer(incoming);if(request.isNotEmpty())PushConnection.cancel(this,request);startActivity(Intent(this,MainActivity::class.java));finish()}catch(_:Exception){label.text="Could not answer. Try again.";accepting=false}
        }else if(accepting)label.text="Connecting your call…"
    }
    private fun decline(){
        declining=true
        if(request.isNotEmpty() && verifiedCall==null){refresh();return}
        val phone=PhoneService.instance
        if(request.isEmpty()){phone?.incomingById(intent.getStringExtra("call_id") ?: "")?.let{phone.hangup(it)};finish();return}
        phone?.calls?.firstOrNull{it.remoteParams?.getCustomHeader("X-OpenWeb-Push-ID")==verifiedCall}?.let{phone.hangup(it)}
        verifiedCall?.let{id->PhoneStore(this).update{it.put("declined_push_call",id).put("declined_push_until",System.currentTimeMillis()+60000)}}
        PushConnection.cancel(this,request)
        worker.execute{try{val a=PhoneStore(this).read() ?: return@execute;PhoneApi(a.getString("server"),a.getString("token")).json("push_dismiss",JSONObject().put("id",request))}catch(_:Exception){}}
        finish()
    }
}
