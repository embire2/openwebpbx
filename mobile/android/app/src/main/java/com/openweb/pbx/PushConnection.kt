/* SPDX-License-Identifier: AGPL-3.0-or-later */
package com.openweb.pbx

import android.app.*
import android.content.*
import android.os.Build
import org.unifiedpush.android.connector.UnifiedPush
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage
import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.Executors

object PushConnection {
    private val worker=Executors.newSingleThreadExecutor()
    fun configure(context:Context){PhoneStore(context).profiles().forEach{configure(context,it)}}
    fun configure(context:Context,stored:JSONObject){
        val profileId=stored.getString("profile_id")
        val settings=stored.optJSONObject("push") ?: return
        if(!settings.optBoolean("enabled") || !TenantConnection.ready(stored)){unregister(context,profileId);state(context,"not_configured",profileId);return}
        try{
            // The embedded open-source distributor talks to the phone's installed
            // Play Services. No Google client SDK or Firebase project is bundled.
            UnifiedPush.saveDistributor(context,context.packageName)
            state(context,"connecting",profileId)
            UnifiedPush.register(context,stored.getString("device_id"),"${context.getString(R.string.app_name)} incoming calls",settings.getString("vapid_public_key"))
        }catch(_:Exception){state(context,"unavailable",profileId)}
    }
    fun state(context:Context,value:String,profileId:String?=null){PhoneStore(context).update(profileId){it.put("push_state",value)};PhoneService.changed?.invoke()}
    fun unregister(context:Context,profileId:String?=null){try{PhoneStore(context).read(profileId)?.optString("device_id")?.takeIf{it.isNotEmpty()}?.let{UnifiedPush.unregister(context,it)}}catch(_:Exception){}}
    fun register(context:Context,endpoint:PushEndpoint,instance:String){worker.execute{try{
        val a=PhoneStore(context).byDevice(instance) ?: return@execute
        if(!TenantConnection.ready(a))return@execute
        if(instance!=a.optString("device_id") || !a.optJSONObject("push")!!.optBoolean("enabled"))return@execute
        val keys=endpoint.pubKeySet ?: throw IllegalArgumentException("Missing notification keys")
        PhoneApi.profile(a).json("push_register",JSONObject().put("endpoint",endpoint.url).put("p256dh",keys.pubKey).put("auth",keys.auth).put("vapid_public_key",a.getJSONObject("push").getString("vapid_public_key")))
        state(context,"ready",a.getString("profile_id"))
    }catch(_:Exception){PhoneStore(context).byDevice(instance)?.let{state(context,"unavailable",it.getString("profile_id"))}}}}
    fun cancel(context:Context,id:String,profileId:String?=null){val manager=context.getSystemService(NotificationManager::class.java);manager.cancel("push:${profileId ?: PhoneStore(context).selectedId()}:$id",12);manager.cancel("push:$id",12)}
    fun notify(context:Context,id:String,expires:Long,profileId:String?=PhoneStore(context).selectedId()){
        val profile=PhoneStore(context).read(profileId) ?: return
        val manager=context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("calls","Incoming calls",NotificationManager.IMPORTANCE_HIGH).apply{lockscreenVisibility=Notification.VISIBILITY_PRIVATE})
        fun action(answer:Boolean,decline:Boolean=false)=PendingIntent.getActivity(context,(profileId+id+answer+decline).hashCode(),Intent(context,IncomingCallActivity::class.java).putExtra("profile_id",profileId).putExtra("push_request",id).putExtra("answer",answer).putExtra("decline",decline),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open=action(false);val answer=action(true);val decline=action(false,true)
        val person=Person.Builder().setName("OpenWebPBX Free Phone caller").build()
        val note=Notification.Builder(context,"calls").setSmallIcon(R.drawable.ic_phone).setContentTitle("Incoming · ${ProfileRules.label(profile)}").setContentText("Connecting your phone…").setContentIntent(open).setCategory(Notification.CATEGORY_CALL).setVisibility(Notification.VISIBILITY_PRIVATE).setTimeoutAfter(((expires-Instant.now().epochSecond)*1000).coerceIn(1,60000))
        // Push does not play a second ringtone; the native incoming SIP call owns audio focus.
        if(Build.VERSION.SDK_INT<34 || manager.canUseFullScreenIntent())note.setFullScreenIntent(open,true)
        note.addAction(Notification.Action.Builder(null,"Answer",answer).build()).addAction(Notification.Action.Builder(null,"Decline",decline).build())
        manager.notify("push:$profileId:$id",12,note.build())
    }
}
class PhoneMessagingService:PushService(){
    override fun onNewEndpoint(endpoint:PushEndpoint,instance:String){PushConnection.register(this,endpoint,instance)}
    override fun onRegistrationFailed(reason:FailedReason,instance:String){PhoneStore(this).byDevice(instance)?.let{PushConnection.state(this,"unavailable",it.getString("profile_id"))}}
    override fun onUnregistered(instance:String){PhoneStore(this).byDevice(instance)?.let{PushConnection.state(this,"unavailable",it.getString("profile_id"))}}
    override fun onTempUnavailable(instance:String){onUnregistered(instance)}
    override fun onMessage(message:PushMessage,instance:String){
        if(!message.decrypted || message.content.size>4096)return
        val saved=PhoneStore(this).byDevice(instance) ?: return
        if(!TenantConnection.ready(saved))return
        val profileId=saved.getString("profile_id")
        val data=try{JSONObject(message.content.toString(Charsets.UTF_8))}catch(_:Exception){return}
        val id=data.optString("request_id")
        if(!id.matches(Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}")) || data.optString("device_id")!=saved.optString("device_id") || data.optLong("expires")<=Instant.now().epochSecond)return
        if(data.optString("event")=="ended"){PushConnection.cancel(this,id,profileId);return}
        if(data.optString("event")!="incoming")return
        try{
            val current=PhoneApi.profile(saved,4000).json("push_call",id=id)
            if(!current.getBoolean("ringing"))return
            val callId=current.getString("call_id")
            if(PhoneService.instance?.calls?.any{PhoneService.instance?.profileId(it)==profileId && it.remoteParams?.getCustomHeader("X-OpenWeb-Push-ID")==callId}==true)return
            PhoneStore(this).update(profileId){it.put("push_pending_id",id).put("push_pending_call",callId)}
            PushConnection.notify(this,id,data.getLong("expires"),profileId)
            if(PhoneService.instance==null && !UpdateManager.get(this).isInstalling){try{startForegroundService(Intent(this,PhoneService::class.java))}catch(_:Exception){/* Tap Answer can start the phone from a visible activity. */}}
        }catch(_:Exception){/* Never resurrect a call that cannot be authenticated. */}
    }
}
